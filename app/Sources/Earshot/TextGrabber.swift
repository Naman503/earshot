import AppKit
import ApplicationServices
import EarshotCore
import ScreenCaptureKit
import Vision

/// Text picked from the screen, plus where it is (top-left screen coordinates)
/// for the highlight.
struct Grab {
    var text: String
    var frame: CGRect?
    var source: String
    /// Text above / below a paragraph, so a tap can read more than one.
    var before: String? = nil
    var after: String? = nil
    /// Finds the spoken words on screen, for the follow-along highlight.
    var locator: WordLocator? = nil
}

/// Finds where a spoken word is on screen (top-left screen coordinates).
/// Called off the main thread, one word after another, in reading order.
protocol WordLocator: AnyObject, Sendable {
    /// `next`: the words spoken right after, to tell apart repeats of a word.
    func locate(_ phrase: String, next: String) -> CGRect?
    /// Where the last word found is now (after the page scrolled or moved).
    func remeasure() -> CGRect?
    /// The app the words are in (the marker only shows while it's in front).
    var pid: pid_t { get }
    /// Debug: the visible area and the last word's box.
    var debugView: String { get }
    /// The visible part of the page (top-left screen coordinates).
    func visibleArea() -> CGRect?
    /// The bottom of the lowest text on the whole page that lies below the
    /// visible area (nil when nothing is below: the page's end is in view).
    func pageBottom(below view: CGRect) -> CGFloat?
    /// Scrolls the page so the last word found stays comfortably in view.
    /// Returns true when it scrolled.
    func scrollToKeepVisible() -> Bool
    /// Whether word boxes stay correct while the page scrolls (OCR boxes don't).
    var tracksScrolling: Bool { get }
    /// About 80 characters of the page's text starting at the word under `point`
    /// (for click-to-jump), or nil when no word is there.
    func textNear(point: CGPoint) -> String?
}

/// Letters and digits only, lowercased: "Earshot's," → "earshots".
func normalizedWord(_ s: String) -> String {
    String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
}

enum GrabUnit: String { case sentence, paragraph, fromHere, section, visible, window, selection }

/// Reads text from any app with the Accessibility API — including web pages in
/// Safari and Chromium browsers, via text markers — and falls back to OCR.
final class TextGrabber {
    private let system = AXUIElementCreateSystemWide()
    private var enabledPIDs = Set<pid_t>()
    private let lock = NSLock()
    private let maxChars = 60_000
    /// Where reading "to the end" stops (set from Settings).
    nonisolated(unsafe) var readScope: ReadScope = .message

    init() {
        AXUIElementSetMessagingTimeout(system, 1.0)
    }

    /// Current pointer position in top-left screen coordinates.
    static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func grab(_ unit: GrabUnit, at point: CGPoint) async -> Grab? {
        if unit == .selection { return selection() }
        if let g = axGrab(unit, at: point), !g.text.isEmpty { return g }
        Log.write("grab: no accessible text at \(point), trying OCR")
        return await ocrGrab(unit, at: point)
    }

    // MARK: Selection

    /// The current selection. With `near`, only a selection the pointer is on
    /// (or, when its position is unknown, one in the app under the pointer) —
    /// so a tap reads a fresh selection, not one left behind elsewhere.
    func selection(near point: CGPoint? = nil) -> Grab? {
        guard let grab = currentSelection() else { return nil }
        guard let point else { return grab }
        if let f = grab.frame { return f.insetBy(dx: -60, dy: -40).contains(point) ? grab : nil }
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        var focusedPID: pid_t = 0, pointerPID: pid_t = 0
        if let f = focused { AXUIElementGetPid(f as! AXUIElement, &focusedPID) }
        if let el = element(at: point) { AXUIElementGetPid(el, &pointerPID) }
        return focusedPID != 0 && focusedPID == pointerPID ? grab : nil
    }

    private func currentSelection() -> Grab? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused.map({ $0 as! AXUIElement }) else { return nil }
        if let s = string(el, kAXSelectedTextAttribute), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rangeValue = attr(el, kAXSelectedTextRangeAttribute)
            let rect = rangeValue.flatMap { paramRect(el, kAXBoundsForRangeParameterizedAttribute, $0) }
            var grab = Grab(text: s, frame: rect, source: "selection")
            var r = CFRange()
            if let web = ancestor(of: el, role: "AXWebArea"), let marked = attr(web, "AXSelectedTextMarkerRange"),
               CFGetTypeID(marked) == AXTextMarkerRangeGetTypeID() {
                grab.locator = webLocator(web: web, start: AXTextMarkerRangeCopyStartMarker(marked as! AXTextMarkerRange), element: el, wholePage: false)
            } else if let full = string(el, kAXValueAttribute), let rangeValue, AXValueGetValue(rangeValue as! AXValue, .cfRange, &r) {
                grab.locator = textViewLocator(el, text: full, start: r.location)
            }
            return grab
        }
        // Web content: the selection lives on the web area as a text-marker range.
        if let web = ancestor(of: el, role: "AXWebArea") ?? (role(el) == "AXWebArea" ? el : nil),
           let range = attr(web, "AXSelectedTextMarkerRange"),
           let s = paramString(web, "AXStringForTextMarkerRange", range), !s.isEmpty {
            var grab = Grab(text: s, frame: paramRect(web, "AXBoundsForTextMarkerRange", range), source: "web selection")
            if CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() {
                grab.locator = webLocator(web: web, start: AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange), element: nil, wholePage: false)
            }
            return grab
        }
        return nil
    }

    // MARK: Accessibility

    private func axGrab(_ unit: GrabUnit, at point: CGPoint) -> Grab? {
        guard var el = element(at: point) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let first = enableWebAccessibility(pid: pid)
        let chromium = hasWebTree(pid: pid)
        let inPage = role(el) == "AXWebArea" || ancestor(of: el, role: "AXWebArea") != nil
        if first || (!inPage && chromium) {
            // The page tree is being (re)built — Chromium apps switch it off on their
            // own, and Claude rebuilds parts of it as replies update. Wait until the
            // text under the pointer is connected to its page again.
            if !first { Log.write("grab: text not connected to its page yet — waiting") }
            for _ in 0..<10 {
                usleep(100_000)
                el = element(at: point) ?? el
                if ancestor(of: el, role: "AXWebArea") != nil || role(el) == "AXWebArea" { break }
            }
        }

        if let web = role(el) == "AXWebArea" ? el : ancestor(of: el, role: "AXWebArea"),
           let g = webGrab(unit, web: web, el: el, at: point) {
            return g
        }
        // Outside web pages, "visible" is exactly what OCR sees.
        if unit == .visible { return nil }
        // In a Chromium app a loose piece of page text isn't a text box: reading it
        // as one gave "a word or two". Only real text fields count there.
        if !chromium || ["AXTextArea", "AXTextField", "AXComboBox"].contains(role(el) ?? ""),
           let g = textAreaGrab(unit, el: el, at: point) { return g }
        if unit == .section { return nil }
        // Still a loose fragment of a Chromium page: reading the screen gets the
        // whole paragraph; this element alone would be a word or two.
        if chromium, role(el) == "AXStaticText", unit != .window {
            Log.write("grab: page text still not connected — reading the screen instead")
            return nil
        }
        if unit == .window, let win = attrElement(el, kAXWindowAttribute) {
            let text = collectText(win, limit: maxChars)
            return text.isEmpty ? nil : Grab(text: text, frame: frame(win), source: "window tree")
        }
        return elementGrab(unit, el: el)
    }

    /// Chromium and Electron only expose web content after an assistive app asks.
    /// Called ahead of time for running apps so the first tap is already fast.
    @discardableResult
    func enableWebAccessibility(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let first = lock.withLock { enabledPIDs.insert(pid).inserted }
        // Asked every time, not once: Chromium/Electron apps switch their page
        // tree off again on their own (after a while, or when the page reloads),
        // and then a tap found no text — a word or OCR — and no highlight.
        let app = AXUIElementCreateApplication(pid)
        let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return first && r == .success
    }

    /// True when the app answers the request that switches a page tree on
    /// (Chromium, Electron).
    private func hasWebTree(pid: pid_t) -> Bool {
        if let known = lock.withLock({ chromiumPIDs[pid] }) { return known }
        var chromium = false
        if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks"),
           let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            chromium = names.contains { $0 == "Electron Framework.framework" || ($0.hasSuffix(" Framework.framework") && !$0.hasPrefix("Sparkle")) }
        }
        lock.withLock { chromiumPIDs[pid] = chromium }
        return chromium
    }
    private var chromiumPIDs: [pid_t: Bool] = [:]

    func webGrab(_ unit: GrabUnit, web: AXUIElement, el: AXUIElement, at point: CGPoint) -> Grab? {
        // WebKit answers AXTextMarkerForPosition; Chromium doesn't, so walk the
        // element's lines and words to find the spot under the pointer.
        guard let marker = paramValue(web, "AXTextMarkerForPosition", axPoint(point)) ?? markerByWalking(web: web, el: el, to: point)
        else { return nil }
        var range: CFTypeRef?
        switch unit {
        case .sentence:
            range = paramValue(web, "AXSentenceTextMarkerRangeForTextMarker", marker)
        case .paragraph:
            // Take the first candidate that actually yields text.
            let candidates: [() -> CFTypeRef?] = [
                { self.paramValue(web, "AXParagraphTextMarkerRangeForTextMarker", marker) },
                { self.paragraphAround(marker, web: web) },
                { self.blockRange(of: el, web: web) },
                { self.paramValue(web, "AXTextMarkerRangeForUIElement", el) },
                { self.paramValue(el, "AXTextMarkerRangeForUIElement", el) },
            ]
            for make in candidates {
                guard let r = make() else { continue }
                let t = paramString(web, "AXStringForTextMarkerRange", r) ?? paramString(el, "AXStringForTextMarkerRange", r)
                if let t, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { range = r; break }
            }
        case .fromHere:
            let sentence = paramValue(web, "AXSentenceTextMarkerRangeForTextMarker", marker)
            let start: CFTypeRef = sentence.map { AXTextMarkerRangeCopyStartMarker($0 as! AXTextMarkerRange) } ?? marker
            if let (_, end) = boundaryMarkers(of: el, web: web) {
                range = AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
            }
        case .window:
            if let start = attr(web, "AXStartTextMarker"), let end = attr(web, "AXEndTextMarker") {
                range = AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
            }
        case .section:
            // Join the section's blocks with line breaks so a heading isn't glued to its text.
            guard let (r, text) = sectionRange(of: el, web: web) else { return nil }
            var grab = Grab(text: String(text.prefix(maxChars)), frame: paramRect(web, "AXBoundsForTextMarkerRange", r), source: "web section")
            grab.locator = webLocator(web: web, start: AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange), element: el, wholePage: false)
            return grab
        case .visible:
            let text = visibleText(web: web)
            return text.isEmpty ? nil : Grab(text: text, frame: nil, source: "web visible")
        case .selection:
            return nil
        }
        guard let range, var text = paramString(web, "AXStringForTextMarkerRange", range) else { return nil }
        text = String(text.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let rect = [.paragraph, .sentence, .section].contains(unit) ? paramRect(web, "AXBoundsForTextMarkerRange", range) : nil
        var grab = Grab(text: text, frame: rect, source: "web text markers")
        if CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() {
            grab.locator = webLocator(web: web, start: AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange), element: el,
                                      wholePage: unit == .fromHere || unit == .window)
        }
        if unit == .paragraph, let n = blockNeighbours(of: el) {
            // Chromium ends "the paragraph" at inline code (and some other inline
            // elements), which lost the rest of the sentence every time. The page's
            // own block holding the pointer has it all: use it when it contains
            // what Chromium returned.
            if let whole = n.current, whole.count > text.count, normalizedWord(whole).contains(normalizedWord(text)) {
                grab.text = whole
            }
            grab.before = n.before
            // A tap between lines starts "below" at the tapped paragraph itself.
            var after = n.after.components(separatedBy: "\n")
            if let first = after.first, normalizedWord(first) == normalizedWord(text) { after.removeFirst() }
            grab.after = after.joined(separator: "\n")
        } else if unit == .paragraph, CFGetTypeID(range) == AXTextMarkerRangeGetTypeID(),
           let (docStart, docEnd) = boundaryMarkers(of: el, web: web) {
            let r = range as! AXTextMarkerRange
            grab.before = paramString(web, "AXStringForTextMarkerRange",
                                      AXTextMarkerRangeCreate(nil, docStart as! AXTextMarker, AXTextMarkerRangeCopyStartMarker(r))).map { String($0.suffix(30_000)) }
            grab.after = paramString(web, "AXStringForTextMarkerRange",
                                     AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyEndMarker(r), docEnd as! AXTextMarker)).map { String($0.prefix(maxChars)) }
        }
        return grab
    }

    /// True when these children are a container's, not a paragraph's: they
    /// include lists, tables or headings, or two or more paragraph-sized groups.
    /// (A reply's container can also hold a loose line like "Created 4 files";
    /// that alone used to make the whole reply count as one paragraph.)
    private func holdsBlocks(_ kids: [AXUIElement]) -> Bool {
        let blockRoles: Set<String> = ["AXList", "AXTable", "AXGrid", "AXOutline", "AXHeading", "AXRow"]
        var paragraphs = 0
        for k in kids {
            let r = role(k) ?? ""
            if blockRoles.contains(r) { return true }
            guard r == "AXGroup" else { continue }
            let own = children(k).filter { role($0) == "AXStaticText" }.compactMap { string($0, kAXValueAttribute) }.joined()
            if own.count > 60 { paragraphs += 1 }
            if paragraphs >= 2 { return true }
        }
        return false
    }

    /// The text range of the paragraph holding `el`: climbs out of links into
    /// the enclosing block, but only while that block holds nothing except
    /// inline text, so a list row or a card never counts as one paragraph.
    private func blockRange(of el: AXUIElement, web: AXUIElement) -> CFTypeRef? {
        let inline: Set<String> = ["AXStaticText", "AXLink", "AXImage"]
        var best: CFTypeRef?
        var cur = el
        for _ in 0..<4 {
            guard let parent = attrElement(cur, kAXParentAttribute), let r = role(parent), r != "AXWebArea" else { break }
            if r == "AXLink" { cur = parent; continue }
            guard children(parent).allSatisfy({ inline.contains(role($0) ?? "") }),
                  let range = paramValue(web, "AXTextMarkerRangeForUIElement", parent),
                  let t = paramString(web, "AXStringForTextMarkerRange", range), t.count < 4000 else { break }
            best = range
            cur = parent
        }
        return best
    }

    /// The blocks before and after the one holding `el`, one per line, kept
    /// inside the post or message it belongs to (an `article`, else the page's
    /// main area), so "paragraphs above / below" never runs into the rest of
    /// the chat, the sidebar or the message box.
    /// The element reading "to the end" stays inside: the reply or post
    /// (`article`), the conversation (`feed`, else the main area), or the page.
    /// Side panels, the message box and other panes are outside the first two.
    func readBoundary(of el: AXUIElement, scope: ReadScope) -> AXUIElement? {
        var cur = el
        var main: AXUIElement?
        for _ in 0..<60 {
            guard let parent = attrElement(cur, kAXParentAttribute) else { break }
            let sub = string(parent, kAXSubroleAttribute)
            if role(parent) == "AXWebArea" { return main ?? parent }
            switch scope {
            case .message:
                if sub == "AXDocumentArticle" || sub == "AXLandmarkMain" { return parent }
            case .conversation:
                if sub == "AXApplicationGroup", string(parent, "AXRoleDescription") == "feed" { return parent }
                if sub == "AXLandmarkMain" { main = main ?? parent }
            case .page:
                break
            }
            cur = parent
        }
        return main
    }

    func blockNeighbours(of el: AXUIElement) -> (before: String, current: String?, after: String)? {
        guard let boundary = readBoundary(of: el, scope: readScope) else { return nil }
        // el and its ancestors up to the boundary, to place a tap that landed
        // between lines or on a tool row.
        var chain: [AXUIElement] = []
        var up: AXUIElement? = el
        while let u = up, !CFEqual(u, boundary), chain.count < 30 { chain.append(u); up = attrElement(u, kAXParentAttribute) }
        var startAt: Int?
        let inline: Set<String> = ["AXStaticText", "AXLink", "AXImage", "AXListMarker"]
        let skip: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXComboBox", "AXCheckBox", "AXRadioButton",
                                 "AXPopUpButton", "AXMenuButton", "AXToolbar", "AXMenu", "AXImage"]
        var blocks: [String] = []
        var current: Int?
        var visited = 0
        func text(_ e: AXUIElement, holds: inout Bool) -> String {
            visited += 1
            if CFEqual(e, el) { holds = true }
            if role(e) == "AXStaticText" { return string(e, kAXValueAttribute) ?? "" }
            let r = role(e)
            if r == "AXListMarker" { return "" }
            // A button inside a sentence (Claude shows file names that way) is
            // part of the sentence: read its label. Other controls stay silent.
            if r == "AXButton" {
                let inner = children(e).map { text($0, holds: &holds) }.joined()
                let label = inner.isEmpty ? (string(e, kAXTitleAttribute) ?? string(e, kAXDescriptionAttribute) ?? "") : inner
                return label.isEmpty ? "" : " " + label + " "  // not glued to the words around it
            }
            if skip.contains(r ?? "") { return "" }
            return readingChildren(e, role: r).map { text($0, holds: &holds) }.joined()
        }
        func walk(_ e: AXUIElement) {
            guard visited < 12000 else { return }
            visited += 1
            let r = role(e) ?? ""
            // An editable area holding the tapped text is what's being read (a
            // document editor, like Claude's doc panel): go into it. Other text
            // boxes (a message being typed) and controls are skipped.
            let editable = r == "AXTextArea" || r == "AXTextField"
            let holdsTap = (skip.contains(r) || editable) && chain.contains { CFEqual($0, e) }
            if startAt == nil, current == nil, CFEqual(e, el) || (holdsTap && !editable) {
                startAt = blocks.count
            }
            if skip.contains(r), !(editable && holdsTap) { return }
            // Status pop-ups and alerts shown inside the page ("… reloaded",
            // "Received message from …") aren't part of what you're reading.
            if r == "AXGroup", let sub = string(e, kAXSubroleAttribute),
               ["AXApplicationStatus", "AXApplicationAlert", "AXApplicationAlertDialog", "AXApplicationLog", "AXApplicationTimer", "AXApplicationMarquee"].contains(sub) {
                return
            }
            let kids = readingChildren(e, role: r)
            // A block that has its own text runs is one paragraph, whatever
            // inline groups (bold, code, links) sit between those runs.
            let ownText = kids.contains { role($0) == "AXStaticText" && !(string($0, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                && !holdsBlocks(kids)
            let leaf = r == "AXHeading" || r == "AXRow" || r == "AXStaticText" || ownText
                || (!kids.isEmpty && kids.allSatisfy { inline.contains(role($0) ?? "") })
            if leaf {
                var holds = false
                let t = r == "AXRow"
                    ? kids.map { var h = false; let s = text($0, holds: &h); if h { holds = true }; return s }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
                    : text(e, holds: &holds)
                let clean = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if holds, current == nil { current = blocks.count; blocks.append(clean); return }
                if !clean.isEmpty { blocks.append(clean) }
                return
            }
            kids.forEach(walk)
        }
        walk(boundary)
        guard visited < 12000 else { Log.write("blocks: gave up after \(visited) elements"); return nil }
        if current == nil, startAt == nil { Log.write("blocks: the tapped element wasn't found among \(blocks.count) blocks") }
        if let i = current { return (blocks[..<i].joined(separator: "\n"), blocks[i], blocks[(i + 1)...].joined(separator: "\n")) }
        guard let i = startAt else { return nil }
        return (blocks[..<i].joined(separator: "\n"), nil, blocks[i...].joined(separator: "\n"))
    }

    /// Start and end of the text reading stays inside (see `readBoundary`).
    private func boundaryMarkers(of el: AXUIElement, web: AXUIElement) -> (CFTypeRef, CFTypeRef)? {
        if let b = readBoundary(of: el, scope: readScope), !CFEqual(b, web),
           let r = paramValue(web, "AXTextMarkerRangeForUIElement", b), CFGetTypeID(r) == AXTextMarkerRangeGetTypeID() {
            return (AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange), AXTextMarkerRangeCopyEndMarker(r as! AXTextMarkerRange))
        }
        guard let start = attr(web, "AXStartTextMarker"), let end = attr(web, "AXEndTextMarker") else { return nil }
        return (start, end)
    }

    /// The heading-to-heading run of blocks around `el`: find the nearest
    /// ancestor that has headings among its children, then take the children
    /// from the heading before the pointer up to the next heading.
    private func sectionRange(of el: AXUIElement, web: AXUIElement) -> (CFTypeRef, String)? {
        var child = el
        for _ in 0..<14 {
            guard let parent = attrElement(child, kAXParentAttribute), role(parent) != "AXWindow" else { return nil }
            let kids = children(parent)
            let isHeading = { (k: AXUIElement) in self.role(k) == "AXHeading" || self.children(k).first.map { self.role($0) == "AXHeading" } == true }
            if let at = kids.firstIndex(where: { CFEqual($0, child) }), kids.contains(where: isHeading) {
                var start = at
                while start > 0, !isHeading(kids[start]) { start -= 1 }
                var end = at
                while end + 1 < kids.count, !isHeading(kids[end + 1]) { end += 1 }
                let ranges = kids[start...end].compactMap { paramValue(web, "AXTextMarkerRangeForUIElement", $0) }
                guard let first = ranges.first, let last = ranges.last else { return nil }
                let text = ranges.compactMap { paramString(web, "AXStringForTextMarkerRange", $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                let whole = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(first as! AXTextMarkerRange),
                                                    AXTextMarkerRangeCopyEndMarker(last as! AXTextMarkerRange))
                return (whole, text)
            }
            if role(parent) == "AXWebArea" { return nil }
            child = parent
        }
        return nil
    }

    /// Text on screen: the page's text pieces whose frames fall inside the
    /// visible part of the page, in reading order. Pieces on the same line or
    /// in the same paragraph are joined with spaces, separate blocks with breaks.
    private func visibleText(web: AXUIElement) -> String {
        guard var rect = frame(web) else { return "" }
        if let window = attrElement(web, kAXWindowAttribute), let wf = frame(window) { rect = rect.intersection(wf) }
        guard rect.width > 0, rect.height > 0 else { return "" }
        var pieces: [(String, CGRect)] = []
        var visited = 0
        func walk(_ el: AXUIElement) {
            guard visited < 6000 else { return }
            visited += 1
            if role(el) == "AXStaticText" {
                if let f = frame(el), f.intersects(rect), let t = string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    pieces.append((t, f))
                }
                return
            }
            // Skip whole subtrees that are scrolled out of view.
            if let f = frame(el), f.height > 0, !f.intersects(rect) { return }
            for c in readingChildren(el, role: role(el)) { walk(c) }
        }
        walk(web)
        var out = ""
        var prev: CGRect?
        for (t, f) in pieces {
            if let p = prev {
                let sameLine = abs(f.minY - p.minY) < p.height * 0.5
                let wrapped = f.minY - p.maxY < p.height * 0.6 && f.minY > p.minY
                out += sameLine || wrapped ? " " : "\n"
            }
            out += t
            prev = f
        }
        return out
    }

    /// Chromium has no paragraph-range call, but it can find paragraph edges.
    private func paragraphAround(_ marker: CFTypeRef, web: AXUIElement) -> CFTypeRef? {
        // Step one forward first so a marker sitting on a paragraph start stays in that paragraph.
        let probe = paramValue(web, "AXNextTextMarkerForTextMarker", marker) ?? marker
        guard let start = paramValue(web, "AXPreviousParagraphStartTextMarkerForTextMarker", probe),
              let end = paramValue(web, "AXNextParagraphEndTextMarkerForTextMarker", marker) else { return nil }
        return AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
    }

    /// The text marker nearest `point`: step through the lines of the element
    /// under the pointer, then through the words of the matching line.
    private func markerByWalking(web: AXUIElement, el: AXUIElement, to point: CGPoint) -> CFTypeRef? {
        guard let elRange = paramValue(web, "AXTextMarkerRangeForUIElement", el) else { return nil }
        let elEnd = AXTextMarkerRangeCopyEndMarker(elRange as! AXTextMarkerRange)
        var m: CFTypeRef = AXTextMarkerRangeCopyStartMarker(elRange as! AXTextMarkerRange)
        for _ in 0..<400 {
            guard let line = paramValue(web, "AXLineTextMarkerRangeForTextMarker", m),
                  let box = paramRect(web, "AXBoundsForTextMarkerRange", line) else { break }
            let lineStart = AXTextMarkerRangeCopyStartMarker(line as! AXTextMarkerRange)
            if point.y <= box.maxY + 2, point.y >= box.minY - 40 {
                return wordMarker(web: web, from: lineStart, lineEnd: AXTextMarkerRangeCopyEndMarker(line as! AXTextMarkerRange), x: point.x) ?? lineStart
            }
            // Next line: one past this line's end, staying inside the element.
            let lineEnd = AXTextMarkerRangeCopyEndMarker(line as! AXTextMarkerRange)
            guard let next = paramValue(web, "AXNextTextMarkerForTextMarker", lineEnd),
                  let check = paramValue(web, "AXTextMarkerRangeForUnorderedTextMarkers", [next, elEnd] as CFArray),
                  (paramString(web, "AXStringForTextMarkerRange", check)?.isEmpty == false) else { break }
            m = next
        }
        return nil  // never reached the pointer's line; let the caller fall back
    }

    private func wordMarker(web: AXUIElement, from start: AXTextMarker, lineEnd: AXTextMarker, x: CGFloat) -> CFTypeRef? {
        var m: CFTypeRef = start
        for _ in 0..<60 {
            guard let wordEnd = paramValue(web, "AXNextWordEndTextMarkerForTextMarker", m),
                  let word = paramValue(web, "AXTextMarkerRangeForUnorderedTextMarkers", [m, wordEnd] as CFArray),
                  let box = paramRect(web, "AXBoundsForTextMarkerRange", word) else { return m }
            if box.maxX >= x { return wordEnd }
            if CFEqual(wordEnd, lineEnd) { return m }
            m = wordEnd
        }
        return m
    }

    /// Native text views (Notes, Mail, TextEdit, Xcode…): index under the pointer → unit.
    private func textAreaGrab(_ unit: GrabUnit, el: AXUIElement, at point: CGPoint) -> Grab? {
        guard let full = string(el, kAXValueAttribute), full.count > 0,
              let rangeValue = paramValue(el, kAXRangeForPositionParameterizedAttribute, axPoint(point)) else { return nil }
        var r = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &r) else { return nil }
        let u: TextUnits.Unit = switch unit {
        case .sentence: .sentence
        case .paragraph: .paragraph
        case .fromHere: .fromHere
        case .section: .section
        default: .all
        }
        let ns = TextUnits.range(of: u, in: full, at: r.location)
        let text = (full as NSString).substring(with: ns).trimmingCharacters(in: .whitespacesAndNewlines)
        var cf = CFRange(location: ns.location, length: ns.length)
        let rect = AXValueCreate(.cfRange, &cf).flatMap { paramRect(el, kAXBoundsForRangeParameterizedAttribute, $0) }
        guard !text.isEmpty else { return nil }
        var grab = Grab(text: String(text.prefix(maxChars)), frame: rect, source: "text view")
        grab.locator = textViewLocator(el, text: full, start: ns.location)
        if unit == .paragraph {
            let s = full as NSString
            grab.before = String(s.substring(to: ns.location).suffix(30_000))
            grab.after = String(s.substring(from: NSMaxRange(ns)).prefix(maxChars))
        }
        return grab
    }

    /// Anything else: the element's own text, widened to its container when that
    /// is still paragraph-sized (a text run inside a list item, a label in a cell…).
    private func elementGrab(_ unit: GrabUnit, el: AXUIElement) -> Grab? {
        var best = el
        var text = ownText(el)
        var current = el
        for _ in 0..<3 {
            guard let parent = attrElement(current, kAXParentAttribute), role(parent) != "AXWindow" else { break }
            let t = collectText(parent, limit: 2500)
            if t.count > 2400 || t.count < text.count { break }
            best = parent
            text = t
            current = parent
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if unit == .sentence, !text.isEmpty { text = TextUnits.substring(.sentence, in: text, at: 0) }
        return text.isEmpty ? nil : Grab(text: text, frame: frame(best), source: "element \(role(best) ?? "?")")
    }

    private func ownText(_ el: AXUIElement) -> String {
        for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(el, key), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return ""
    }

    /// Depth-first text of an element subtree, one line per text-bearing node.
    func collectText(_ root: AXUIElement, limit: Int) -> String {
        var lines: [String] = []
        var total = 0
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard total < limit, visited < 4000, depth < 40 else { return }
            visited += 1
            let r = role(el) ?? ""
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"].contains(r) || r == "AXLink" && children(el).isEmpty {
                let t = ownText(el).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { lines.append(t); total += t.count }
                if r != "AXHeading" { return }
            }
            for c in readingChildren(el, role: r) { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// What auto-read compares from one second to the next.
    struct PageSnapshot {
        var app: String
        var windowID: Int
        var url: String?
        var title: String
        var text: String
        /// Text in the app's focused input field (so the user's own typing isn't read).
        var typed: String?

        var host: String? { url.flatMap { URL(string: $0)?.host } }
        /// Identifies "the same page": URL without fragment, else the window title.
        var key: String {
            guard let url, var c = URLComponents(string: url) else { return "\(app)|\(windowID)|\(title)" }
            c.fragment = nil
            return "\(app)|\(c.string ?? url)"
        }
    }

    private var webAreaCache: [Int: AXUIElement] = [:]

    /// Text of a window: its main web area via text markers, else its
    /// accessibility tree. `window` nil means the app's focused window.
    /// Which app and site is in front, without reading the page: cheap enough
    /// to check every second (the page web area is found once per window).
    func pageIdentity(pid: pid_t) -> (app: String, host: String?)? {
        let root = AXUIElementCreateApplication(pid)
        guard let win = attrElement(root, kAXFocusedWindowAttribute) else { return nil }
        let windowID = Int(CFHash(win))
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        if webAreaCache[windowID] == nil, !identityChecked.contains(windowID) {
            identityChecked.insert(windowID)
            webAreaCache[windowID] = largestWebArea(in: win)
        }
        let url = webAreaCache[windowID].flatMap { (attr($0, "AXURL") as? URL)?.absoluteString ?? attr($0, "AXURL") as? String }
        return (app, url.flatMap { URL(string: $0)?.host })
    }
    private var identityChecked = Set<Int>()

    func pageSnapshot(pid: pid_t, window: AXUIElement? = nil) -> PageSnapshot? {
        let root = AXUIElementCreateApplication(pid)
        guard let win = window ?? attrElement(root, kAXFocusedWindowAttribute) else { return nil }
        let windowID = Int(CFHash(win))
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        let title = string(win, kAXTitleAttribute) ?? ""
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focused)
        let typed = focused.flatMap { f -> String? in
            let el = f as! AXUIElement
            guard ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role(el) ?? "") else { return nil }
            return string(el, kAXValueAttribute).flatMap { $0.isEmpty ? nil : $0 }
        }

        var web = webAreaCache[windowID]
        if web == nil || webText(web!) == nil {
            web = largestWebArea(in: win)
            webAreaCache[windowID] = web
        }
        if let web, let text = webText(web) {
            let url = (attr(web, "AXURL") as? URL)?.absoluteString ?? attr(web, "AXURL") as? String
            return PageSnapshot(app: appName, windowID: windowID, url: url, title: title, text: text, typed: typed)
        }
        return PageSnapshot(app: appName, windowID: windowID, url: nil, title: title,
                            text: collectText(win, limit: 30_000), typed: typed)
    }

    private func webText(_ web: AXUIElement) -> String? {
        guard let start = attr(web, "AXStartTextMarker"), let end = attr(web, "AXEndTextMarker") else { return nil }
        return paramString(web, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker))
    }

    /// Apps like Claude wrap their content in an inner web area; take the one with the most text.
    private func largestWebArea(in win: AXUIElement) -> AXUIElement? {
        var best: (AXUIElement, Int)?
        var queue = [win]
        var visited = 0
        while !queue.isEmpty, visited < 2500 {
            let el = queue.removeFirst()
            visited += 1
            if role(el) == "AXWebArea" {
                let n = webText(el)?.count ?? 0
                if n > (best?.1 ?? -1) { best = (el, n) }
                if n >= 200 { continue }  // a real page; don't look inside it
            }
            queue.append(contentsOf: children(el))
        }
        return best?.0
    }

    /// Whole text of the web page in the named app's front window (for --summarize-app).
    func pageText(inApp name: String) -> String? { pageInfo(inApp: name)?.text }

    func pageInfo(inApp name: String) -> (text: String, url: String?)? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == name }
        guard let app = apps.first(where: { $0.activationPolicy == .regular }) ?? apps.first else { return nil }
        enableWebAccessibility(pid: app.processIdentifier)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = attrElement(root, kAXFocusedWindowAttribute) ?? (attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        var queue = [win]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let el = queue.removeFirst()
            visited += 1
            if role(el) == "AXWebArea", let start = attr(el, "AXStartTextMarker"), let end = attr(el, "AXEndTextMarker") {
                let range = AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
                guard let text = paramString(el, "AXStringForTextMarkerRange", range) else { return nil }
                return (text, (attr(el, "AXURL") as? URL)?.absoluteString ?? attr(el, "AXURL") as? String)
            }
            queue.append(contentsOf: children(el))
        }
        return nil
    }

    /// The static text containing `needle` in the named app's front window (debug).
    func findText(inApp name: String, needle: String) -> AXUIElement? {
        // "pid:123" targets one process (e.g. a test browser beside the user's own).
        let named = NSWorkspace.shared.runningApplications.filter {
            name.hasPrefix("pid:") ? "pid:\($0.processIdentifier)" == name : $0.localizedName == name
        }
        guard !named.isEmpty else { Log.write("findText: no app \(name)"); return nil }
        named.forEach { enableWebAccessibility(pid: $0.processIdentifier) }
        if name.hasPrefix("pid:") {
            // Test browsers only: plain Chrome builds its page tree for this request.
            named.forEach { AXUIElementSetAttributeValue(AXUIElementCreateApplication($0.processIdentifier), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        usleep(800_000)
        // Every app of that name (a test browser may run beside the user's own).
        let wins = named.flatMap { (attr(AXUIElementCreateApplication($0.processIdentifier), kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
        var found: AXUIElement?
        var visited = 0
        func walk(_ el: AXUIElement) {
            guard found == nil, visited < 40000 else { return }
            visited += 1
            if role(el) == "AXStaticText", let v = string(el, kAXValueAttribute) {
                if needle == "*" ? (v.count > 80 && (frame(el)?.minY ?? 0) > 150) : v.contains(needle) { found = el }
                return
            }
            for c in children(el) { walk(c) }
        }
        wins.forEach(walk)
        Log.write("findText: \(wins.count) windows, visited \(visited)")
        return found
    }

    /// All text in the named app's windows, one text piece per line, with each
    /// piece's role path (debug, to see what gets read).
    func dumpTexts(inApp name: String) -> String {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.localizedName == name }
        guard let app = apps.first(where: { $0.activationPolicy == .regular }) else { return "" }
        enableWebAccessibility(pid: app.processIdentifier)
        usleep(800_000)  // Chromium builds its tree on first request
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var out = ""
        var visited = 0
        func walk(_ el: AXUIElement, _ path: String) {
            guard visited < 40000 else { return }
            visited += 1
            let r = role(el) ?? "?"
            if r == "AXStaticText" {
                if let v = string(el, kAXValueAttribute), !v.trimmingCharacters(in: .whitespaces).isEmpty { out += "[\(path)] \(v)\n" }
                return
            }
            let classes = (attr(el, "AXDOMClassList") as? [String])?.prefix(2).joined(separator: ".") ?? ""
            let tag = (string(el, kAXSubroleAttribute) ?? r).replacingOccurrences(of: "AX", with: "") + (classes.isEmpty ? "" : ".\(classes)")
            for c in children(el) { walk(c, String((path + ">" + tag).suffix(90))) }
        }
        let wins = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        wins.forEach { walk($0, "") }
        Log.write("dumpTexts: \(apps.count) apps, \(wins.count) windows, visited \(visited)")
        return out
    }

    /// Children of the ancestor `up` levels above `el`: role, subrole and text (debug).
    func describeChildren(of el: AXUIElement, up: Int) -> String {
        var cur = el
        for _ in 0..<up { if let p = attrElement(cur, kAXParentAttribute) { cur = p } }
        return children(cur).enumerated().map { i, c in
            let v = (string(c, kAXValueAttribute) ?? string(c, kAXDescriptionAttribute) ?? "").prefix(50)
            return "\(i) \(role(c) ?? "?")/\(string(c, kAXSubroleAttribute) ?? "") kids=\(children(c).count) “\(v)”"
        }.joined(separator: "\n")
    }

    /// Ancestor chain of `el` with roles, DOM classes and child counts (debug).
    func describeAncestors(_ el: AXUIElement) -> String {
        var out = ""
        var cur: AXUIElement? = el
        for depth in 0..<16 {
            guard let c = cur else { break }
            let kids = children(c)
            let classes = (attr(c, "AXDOMClassList") as? [String])?.prefix(4).joined(separator: ".") ?? ""
            let kidRoles = kids.prefix(8).map { role($0) ?? "?" }.joined(separator: ",")
            out += "\(depth) \(role(c) ?? "?")/\(string(c, kAXSubroleAttribute) ?? "")/\(string(c, "AXRoleDescription") ?? "") .\(classes) kids=\(kids.count) [\(kidRoles)]\n"
            if role(c) == "AXWebArea" { break }
            cur = attrElement(c, kAXParentAttribute)
        }
        return out
    }

    /// Center of a long static text in the named app's front window (for --probe-app).
    func samplePoint(inApp name: String) -> CGPoint? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { return nil }
        enableWebAccessibility(pid: app.processIdentifier)
        usleep(500_000)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = attrElement(root, kAXFocusedWindowAttribute) ?? (attr(root, kAXWindowsAttribute) as? [AXUIElement])?.first else { return nil }
        var found: CGPoint?
        var visited = 0
        func walk(_ el: AXUIElement) {
            guard found == nil, visited < 6000 else { return }
            visited += 1
            if role(el) == "AXStaticText", let t = string(el, kAXValueAttribute), t.count > 80, let f = frame(el),
               f.width > 100, f.height > 8, f.minY > 80 {
                found = CGPoint(x: f.minX + min(f.width / 2, 120), y: f.minY + min(f.height / 2, 8))
                if let web = ancestor(of: el, role: "AXWebArea") {
                    for unit in [GrabUnit.sentence, .paragraph, .section, .visible, .fromHere] {
                        let t0 = Date()
                        let g = webGrab(unit, web: web, el: el, at: found!)
                        Log.write("sample \(unit.rawValue): \(Int(Date().timeIntervalSince(t0) * 1000)) ms, \(g?.text.count ?? -1) chars, frame=\(String(describing: g?.frame)), starts \"\(g?.text.prefix(25) ?? "")\"")
                    }
                }
                return
            }
            for c in children(el) { walk(c) }
        }
        walk(win)
        return found
    }

    /// Describes what Accessibility exposes at `point` (for --probe).
    /// Short description of what's under the pointer and its ancestors (for
    /// taps that grab almost nothing).
    func chainAt(_ point: CGPoint) -> String {
        guard let el = element(at: point) else { return "no element" }
        var out: [String] = []
        var cur: AXUIElement? = el
        while let c = cur, out.count < 14 {
            let cls = (attr(c, "AXDOMClassList") as? [String])?.prefix(2).joined(separator: ".") ?? ""
            let text = (string(c, kAXValueAttribute) ?? string(c, kAXTitleAttribute) ?? string(c, kAXDescriptionAttribute) ?? "").prefix(30)
            let f = frame(c).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
            out.append("\(role(c) ?? "?")/\(string(c, kAXSubroleAttribute) ?? "") .\(cls) kids=\(children(c).count) [\(f)] “\(text)”")
            cur = attrElement(c, kAXParentAttribute)
        }
        return out.joined(separator: "\n  < ")
    }

    func diagnose(at point: CGPoint) -> String {
        guard let el = element(at: point) else { return "no element" }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        var chain: [String] = []
        var cur: AXUIElement? = el
        while let c = cur, chain.count < 12 {
            chain.append(role(c) ?? "?")
            cur = attrElement(c, kAXParentAttribute)
        }
        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(el, &names)
        let web = role(el) == "AXWebArea" ? el : ancestor(of: el, role: "AXWebArea")
        let flipped = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        var tries: [String] = []
        for (name, target) in [("el", el), ("web", web)] {
            guard let target else { continue }
            for (pname, p) in [("topLeft", point), ("flipped", flipped)] {
                let m = paramValue(target, "AXTextMarkerForPosition", axPoint(p))
                let para = m.flatMap { paramValue(target, "AXParagraphTextMarkerRangeForTextMarker", $0) }
                    .flatMap { paramString(target, "AXStringForTextMarkerRange", $0) }
                tries.append("\(name)/\(pname): marker=\(m != nil) para=\(para.map { String($0.prefix(60)) } ?? "nil")")
            }
        }
        for size in [6.0, 24.0, 60.0] {
            for (name, target) in [("el", el), ("web", web)] {
                guard let target else { continue }
                var rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
                let m = AXValueCreate(.cgRect, &rect).flatMap { paramValue(target, "AXStartTextMarkerForBounds", $0) }
                let para = m.flatMap { paramValue(target, "AXParagraphTextMarkerRangeForTextMarker", $0) }
                    .flatMap { paramString(target, "AXStringForTextMarkerRange", $0) }
                tries.append("bounds\(Int(size))/\(name): marker=\(m != nil) para=\(para.map { String($0.prefix(60)) } ?? "nil")")
            }
        }
        return "pid=\(pid) app=\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") chain=\(chain.joined(separator: "<")) "
            + "webArea=\(web != nil) | " + tries.joined(separator: " | ")
    }

    // MARK: OCR fallback

    private func ocrGrab(_ unit: GrabUnit, at point: CGPoint) async -> Grab? {
        guard let (image, windowFrame, pid) = await captureWindow(at: point) else { return nil }
        let lines = await recognize(image, in: windowFrame)
        let blocks = OCRLayout.blocks(lines)
        guard !blocks.isEmpty else { return nil }
        func locator(_ chosen: ArraySlice<OCRLayout.Block>) -> OCRLocator {
            OCRLocator(lines: chosen.flatMap(\.lines), pid: pid)
        }
        if unit == .window || unit == .visible {
            return Grab(text: blocks.map(\.text).joined(separator: "\n"), frame: windowFrame, source: "OCR",
                        locator: locator(blocks[...]))
        }
        guard let i = OCRLayout.blockIndex(at: point, in: blocks) else { return nil }
        switch unit {
        case .fromHere:
            return Grab(text: blocks[i...].map(\.text).joined(separator: "\n"), frame: blocks[i].rect, source: "OCR",
                        locator: locator(blocks[i...]))
        case .section:
            let r = OCRLayout.sectionRange(blocks, around: i)
            let rect = blocks[r].dropFirst().reduce(blocks[r.lowerBound].rect) { $0.union($1.rect) }
            return Grab(text: blocks[r].map(\.text).joined(separator: "\n"), frame: rect, source: "OCR",
                        locator: locator(blocks[r]))
        case .sentence:
            return Grab(text: TextUnits.substring(.sentence, in: blocks[i].text, at: 0), frame: blocks[i].rect, source: "OCR",
                        locator: locator(blocks[i...i]))
        default:
            // The reading may expand to neighbouring paragraphs, so the word
            // boxes cover the whole page; the first match finds its own start.
            return Grab(text: blocks[i].text, frame: blocks[i].rect, source: "OCR",
                        before: blocks[..<i].map(\.text).joined(separator: "\n"),
                        after: blocks[(i + 1)...].map(\.text).joined(separator: "\n"),
                        locator: locator(blocks[...]))
        }
    }

    /// Screenshot of the topmost normal window under the pointer.
    private func captureWindow(at point: CGPoint) async -> (CGImage, CGRect, pid_t)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let me = ProcessInfo.processInfo.processIdentifier
            // SCShareableContent lists windows front to back.
            guard let window = content.windows.first(where: {
                $0.windowLayer == 0 && $0.frame.contains(point) && $0.owningApplication?.processID != me
            }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.frame.contains(NSPoint(x: point.x, y: $0.frame.midY)) }?.backingScaleFactor ?? 2
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            await MainActor.run { Permissions.shared.markScreenRecordingGranted() }
            return (image, window.frame, window.owningApplication?.processID ?? 0)
        } catch {
            Log.write("grab: screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func recognize(_ image: CGImage, in frame: CGRect) async -> [OCRLayout.Line] {
        await withCheckedContinuation { c in
            let request = VNRecognizeTextRequest { req, _ in
                let obs = req.results as? [VNRecognizedTextObservation] ?? []
                let lines = obs.compactMap { o -> OCRLayout.Line? in
                    guard let text = o.topCandidates(1).first?.string else { return nil }
                    let b = o.boundingBox  // normalized, bottom-left origin
                    let rect = CGRect(x: frame.minX + b.minX * frame.width,
                                      y: frame.minY + (1 - b.maxY) * frame.height,
                                      width: b.width * frame.width, height: b.height * frame.height)
                    return OCRLayout.Line(text: text, rect: rect)
                }
                c.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                c.resume(returning: [])
            }
        }
    }

    // MARK: AX helpers

    private func element(at p: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success, let hit = el else { return nil }
        return deepest(at: p, from: hit)
    }

    /// The system's hit test stops at some containers — a page embedded in
    /// another page (Claude's doc panel) comes back as the whole embedded page,
    /// and reading then started at its top ("Tab 1"). From a page or a large
    /// box, step down to the smallest child under the point.
    private func deepest(at p: CGPoint, from hit: AXUIElement) -> AXUIElement {
        let r = role(hit) ?? ""
        let big = frame(hit).map { $0.width > 260 && $0.height > 80 } ?? false
        guard r == "AXWebArea" || (r == "AXGroup" && big) || r == "AXScrollArea" else { return hit }
        // Search the box for the line of text under the point. Only branches
        // whose box contains the point are opened, and empty overlays (Claude
        // lays a transparent one over its doc panel) are skipped.
        var best: (AXUIElement, CGFloat)?
        var visited = 0
        func walk(_ e: AXUIElement) {
            guard visited < 4000 else { return }
            visited += 1
            for c in children(e) {
                guard let f = frame(c), f.contains(p) else { continue }
                if string(c, kAXSubroleAttribute) == "AXEmptyGroup" { continue }
                if role(c) == "AXStaticText" {
                    let area = f.width * f.height
                    if best == nil || area < best!.1 { best = (c, area) }
                } else {
                    walk(c)
                }
            }
        }
        walk(hit)
        return best?.0 ?? hit
    }

    private func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func attrElement(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    func debugString(_ el: AXUIElement) -> String { string(el, kAXValueAttribute) ?? "" }
    private func role(_ el: AXUIElement) -> String? { string(el, kAXRoleAttribute) }
    private func children(_ el: AXUIElement) -> [AXUIElement] { attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

    /// Children to read through: a table lists its rows *and* its columns, so
    /// walking every child read each cell twice (row by row, then column by
    /// column). Tables give just their rows.
    func readingChildren(_ el: AXUIElement, role r: String?) -> [AXUIElement] {
        if r == "AXTable" || r == "AXGrid" || r == "AXOutline", let rows = attr(el, "AXRows") as? [AXUIElement], !rows.isEmpty {
            return rows
        }
        return children(el)
    }

    private func frame(_ el: AXUIElement) -> CGRect? {
        guard let v = attr(el, "AXFrame") else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    private func ancestor(of el: AXUIElement, role wanted: String) -> AXUIElement? {
        var cur = el
        for _ in 0..<60 {
            guard let p = attrElement(cur, kAXParentAttribute) else { return nil }
            if role(p) == wanted { return p }
            cur = p
        }
        return nil
    }

    private func axPoint(_ p: CGPoint) -> AXValue {
        var pt = p
        return AXValueCreate(.cgPoint, &pt)!
    }

    private func paramValue(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &v) == .success ? v : nil
    }

    private func paramString(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> String? {
        paramValue(el, name, param) as? String
    }

    private func paramRect(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> CGRect? {
        guard let v = paramValue(el, name, param), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) && r.width > 0 ? r : nil
    }
}

// MARK: Follow-along word finding

extension TextGrabber {
    func elementFrame(_ el: AXUIElement) -> CGRect? { frame(el) }

    /// The bottom of the lowest page text below `view` (the app reports text
    /// boxes unclipped, so text scrolled out of sight still has its true
    /// place). Walks the page from its end backwards and stops once it's back
    /// in the upper half of the view, so it only looks at the last stretch.
    func pageBottom(from el: AXUIElement, below view: CGRect, column: ClosedRange<CGFloat>? = nil) -> CGFloat? {
        var web: AXUIElement? = el
        while let w = web, role(w) != "AXWebArea" { web = attr(w, kAXParentAttribute).map { $0 as! AXUIElement } }
        guard let root = web else { return nil }
        var lowest: CGFloat?
        var done = false
        var seen = 0
        var upper = 0
        func walk(_ e: AXUIElement, depth: Int) {
            guard !done, depth < 80, seen < 3000 else { return }
            seen += 1
            if role(e) == "AXStaticText" {
                let len = ((string(e, kAXValueAttribute) ?? "") as NSString).length
                guard len > 0, let b = textBounds(e, NSRange(location: 0, length: len)) ?? frame(e) else { return }
                if let c = column, b.maxX < c.lowerBound - 40 || b.minX > c.upperBound + 40 { return }  // another column
                if b.maxY > view.maxY + 2 { lowest = max(lowest ?? 0, b.maxY) }
                // Several texts in a row back up in the page: nothing lower is
                // left (one alone could be a header or overlay out of order).
                if b.maxY < view.midY { upper += 1; if upper >= 5 { done = true } } else { upper = 0 }
                return
            }
            for c in children(e).reversed() { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return lowest
    }

    func webAreaFrame(of el: AXUIElement) -> CGRect? {
        var web: AXUIElement? = el
        while let w = web, role(w) != "AXWebArea" { web = attr(w, kAXParentAttribute).map { $0 as! AXUIElement } }
        return web.flatMap { frame($0) }
    }

    /// Debug: the last texts in the page (document order) with their real
    /// (unclipped) text boxes.
    func lastTexts(near el: AXUIElement, count: Int) -> [String] {
        var web: AXUIElement? = el
        while let w = web, role(w) != "AXWebArea" { web = attr(w, kAXParentAttribute).map { $0 as! AXUIElement } }
        guard let root = web else { return ["no web area"] }
        var texts: [AXUIElement] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 80, texts.count < 20000 else { return }
            if role(e) == "AXStaticText" { texts.append(e); return }
            for c in children(e) { walk(c, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return texts.suffix(count).map { t in
            let v = string(t, kAXValueAttribute) ?? ""
            let b = textBounds(t, NSRange(location: 0, length: (v as NSString).length))
            return "\(b.map { "\($0)" } ?? "?") frame \(frame(t).map { "\($0)" } ?? "?") “\(v.prefix(40))”"
        } + ["\(texts.count) texts in all"]
    }

    /// Debug: role, subrole and frame of each ancestor.
    func ancestorChain(_ el: AXUIElement) -> [String] {
        var out: [String] = []
        var cur: AXUIElement? = el
        while let c = cur, out.count < 40 {
            let r = role(c) ?? "?"
            let sub = string(c, kAXSubroleAttribute) ?? ""
            let names = (try? { () -> [String] in
                var n: CFArray?
                AXUIElementCopyAttributeNames(c, &n)
                return (n as? [String]) ?? []
            }()) ?? []
            let scrolly = names.filter { $0.lowercased().contains("scroll") }
            out.append("\(r)/\(sub) \(frame(c).map { "\($0)" } ?? "?") \(scrolly)")
            cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return out
    }

    /// The app's own "scroll this into view" (as screen readers use it).
    func scrollIntoView(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, "AXScrollToVisible" as CFString) == .success
    }

    /// The part of `el` that's visible: its frame within its window's.
    func visibleFrame(of el: AXUIElement) -> CGRect? {
        guard let f = frame(el) else { return nil }
        guard let w = attrElement(el, kAXWindowAttribute), let wf = frame(w) else { return f }
        let v = f.intersection(wf)
        return v.isNull ? nil : v
    }

    func textBounds(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &cf).flatMap { paramRect(el, kAXBoundsForRangeParameterizedAttribute, $0) }
    }
}


/// Finds spoken words by searching ahead through the text from where the
/// reading started, then asks the element holding the word for its box.
/// The text is a run of elements: a native text view is one run; a web page is
/// its text pieces in order (Chromium only gives exact boxes per element).
final class TextRunLocator: WordLocator, @unchecked Sendable {
    struct Run { let element: AXUIElement; let start: Int; let length: Int }

    private let grabber: TextGrabber
    private let load: () -> (runs: [Run], text: String, cursor: Int)?
    private var runs: [Run] = []
    private var text: NSString = ""
    private var cursor = 0
    private var loaded = false
    private var found = false
    /// Where the last word was found (debug).
    var lastRange: NSRange?

    let pid: pid_t
    /// The visible part of the page (top-left screen coordinates).
    private let viewport: () -> CGRect?

    init(grabber: TextGrabber, pid: pid_t, viewport: @escaping () -> CGRect? = { nil },
         load: @escaping () -> (runs: [Run], text: String, cursor: Int)?) {
        self.grabber = grabber
        self.pid = pid
        self.viewport = viewport
        self.load = load
    }

    /// Near the bottom (or above the top) of the visible area: ask the app to
    /// bring a line further on into view (it scrolls just enough to show it), so
    /// the spoken word lands about a third of the way down. Uses the app's own
    /// "scroll into view", which handles nested scroll areas like Claude's docs.
    func visibleArea() -> CGRect? { viewport() }

    var tracksScrolling: Bool { true }

    /// The page text from the word you clicked: hit the text line under the
    /// point, then find which word's box holds it.
    func textNear(point: CGPoint) -> String? {
        guard loaded else { return nil }
        for run in runs {
            guard run.length > 0, let f = grabber.elementFrame(run.element), f.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            var hit: Int?
            var looked = 0
            text.enumerateSubstrings(in: NSRange(location: run.start, length: run.length), options: .byWords) { _, r, _, stop in
                looked += 1
                if looked > 600 { stop.pointee = true; return }
                let local = NSRange(location: r.location - run.start, length: r.length)
                if let b = self.grabber.textBounds(run.element, local), b.insetBy(dx: -1, dy: -2).contains(point) {
                    hit = r.location
                    stop.pointee = true
                }
            }
            if let at = hit {
                return text.substring(with: NSRange(location: at, length: min(90, text.length - at)))
            }
        }
        return nil
    }

    func pageBottom(below view: CGRect) -> CGFloat? {
        guard loaded, let el = runs.last?.element else { return nil }
        // The reading's own column, so side panels and pop-ups don't count.
        let current = lastRange.flatMap { r in runs.first { NSMaxRange(r) > $0.start && r.location < $0.start + $0.length } }
        let column = (current?.element).flatMap { grabber.elementFrame($0) } ?? grabber.elementFrame(el)
        return grabber.pageBottom(from: el, below: view, column: column.map { $0.minX...$0.maxX })
    }

    var debugView: String {
        "visible area \(viewport().map { "\($0)" } ?? "unknown"), last word \(lastRange.flatMap { box(for: $0) }.map { "\($0)" } ?? "none")"
    }

    func scrollToKeepVisible() -> Bool {
        guard loaded, let range = lastRange, let box = box(for: range), let view = viewport(), view.height > 80,
              let i = runs.firstIndex(where: { NSMaxRange(range) > $0.start && range.location < $0.start + $0.length }) else { return false }
        let h = view.height
        if box.maxY > view.minY + h * 0.8 || box.minY > view.maxY {
            // Going down: the first piece of text about 60% of a screen below the word.
            for run in runs[i...].prefix(400) {
                guard let f = grabber.elementFrame(run.element) else { continue }
                if f.minY >= box.minY + h * 0.6 { return grabber.scrollIntoView(run.element) }
            }
            return runs.last.map { grabber.scrollIntoView($0.element) } ?? false
        }
        if box.maxY < view.minY + h * 0.1 {
            // Above the visible area: bring the word itself into view.
            return grabber.scrollIntoView(runs[i].element)
        }
        return false
    }

    func locate(_ phrase: String, next: String) -> CGRect? {
        if !loaded {
            // Retried on the next word if the page wasn't readable yet (being
            // rebuilt): a single failed load used to leave the highlight off for
            // the whole reading.
            guard let l = load() else { return nil }
            loaded = true
            (runs, text, cursor) = (l.runs, l.text as NSString, l.cursor)
        }
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        let following = next.split(whereSeparator: \.isWhitespace).map(String.init).prefix(3)
        guard let first = words.first, let r = place(first, then: Array(words.dropFirst()) + following) else {
            misses += 1
            return nil
        }
        misses = 0
        var range = r
        for w in words.dropFirst() {
            if let n = find(w, from: NSMaxRange(range), within: 24) { range = NSUnionRange(range, n) }
        }
        found = true
        cursor = NSMaxRange(range)
        lastRange = range
        if let b = box(for: range) { return b }
        // Found in the text but nothing measurable: the page rebuilt those
        // elements (scrolled, re-rendered). Read it afresh and find the place again.
        guard !reloading else { return nil }
        reloading = true
        defer { reloading = false }
        loaded = false
        found = false
        return locate(phrase, next: next)
    }
    private var reloading = false
    /// Words in a row that couldn't be placed.
    private var misses = 0

    func remeasure() -> CGRect? { lastRange.flatMap { box(for: $0) } }

    /// Debug: the page text around the current position.
    var debugContext: String {
        let lo = max(0, cursor - 60), hi = min(text.length, cursor + 160)
        return text.substring(with: NSRange(location: lo, length: hi - lo)).replacingOccurrences(of: "\n", with: "⏎") + " (at \(cursor) of \(text.length))"
    }

    /// Where `word` is on the page: the first place after the cursor that the
    /// following spoken words also come after, so a common word ("the") never
    /// jumps ahead to a later line. Close by first, then further, then (for the
    /// first word of a reading, when paragraphs above were added) behind.
    private func place(_ word: String, then after: [String]) -> NSRange? {
        let core = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard !core.isEmpty else { return nil }
        let from = min(cursor, text.length)
        let near = NSRange(location: from, length: min(400, text.length - from))
        let far = NSRange(location: from, length: min(1500, text.length - from))
        let ahead = NSRange(location: from, length: text.length - from)
        let behind = NSRange(location: 0, length: from)
        // (where, search backwards, the next words must follow directly)
        // Only after several words in a row weren't found (text the voice said
        // differently, a skipped code line) look further ahead — never on a
        // single miss, which made the marker jump to a repeated phrase paragraphs on.
        let lost = misses >= 3
        let passes: [(NSRange, Bool, Bool)] = found
            ? [(near, false, true), (NSRange(location: from, length: min(150, text.length - from)), false, false)]
                + (lost ? [(far, false, true), (NSRange(location: max(0, from - 1500), length: from - max(0, from - 1500)), true, true)] : [])
            : [(ahead, false, true), (behind, true, true), (near, false, false)]
        for (window, backwards, strict) in passes {
            var search = window
            while search.length > 0, let r = wholeWord(core, in: search, backwards: backwards) {
                if follows(after, from: NSMaxRange(r), strict: strict) { return r }
                search = backwards ? NSRange(location: search.location, length: r.location - search.location)
                                   : NSRange(location: NSMaxRange(r), length: NSMaxRange(search) - NSMaxRange(r))
            }
        }
        // Nothing confirmed: accept only a match right next to where we are.
        if found, let r = wholeWord(core, in: NSRange(location: from, length: min(40, text.length - from)), backwards: false) { return r }
        return nil
    }

    /// Strict: the next words (up to three) come straight after, as a phrase.
    /// Loose: at least two of them come within the next 60 characters, in order.
    private func follows(_ words: [String], from start: Int, strict: Bool) -> Bool {
        let wanted = words.map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return true }
        var at = start, hits = 0
        for w in wanted.prefix(strict ? 3 : 4) {
            let span = strict ? min(w.utf16.count + 8, text.length - at) : min(60, text.length - at)
            guard span > 0, let r = wholeWord(w, in: NSRange(location: at, length: span), backwards: false) else {
                if strict { return false }
                continue
            }
            hits += 1
            at = NSMaxRange(r)
        }
        return strict || hits >= min(2, wanted.count)
    }

    /// Box of a text range, piece by piece across elements, kept to one line.
    private func box(for range: NSRange) -> CGRect? {
        var boxes: [CGRect] = []
        for run in runs where run.start < NSMaxRange(range) && run.start + run.length > range.location {
            let lo = max(range.location, run.start), hi = min(NSMaxRange(range), run.start + run.length)
            // Word by word: a range that wraps onto the next line would
            // otherwise come back as one box covering both lines.
            text.enumerateSubstrings(in: NSRange(location: lo, length: hi - lo), options: .byWords) { _, r, _, _ in
                if let b = self.grabber.textBounds(run.element, NSRange(location: r.location - run.start, length: r.length)) { boxes.append(b) }
            }
        }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { acc, b in abs(b.midY - acc.midY) < acc.height * 0.5 ? acc.union(b) : acc }
    }

    private func find(_ word: String, from: Int, within: Int? = nil) -> NSRange? {
        let core = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        guard !core.isEmpty else { return nil }
        let from = min(from, text.length)
        let ahead = within ?? (found ? 400 : 2000)
        if let r = wholeWord(core, in: NSRange(location: from, length: min(ahead, text.length - from)), backwards: false) { return r }
        // The first word may sit above the start (paragraphs above were added).
        guard !found, within == nil else { return nil }
        let back = max(0, from - 30_000)
        return wholeWord(core, in: NSRange(location: back, length: from - back), backwards: true)
    }

    private func wholeWord(_ word: String, in range: NSRange, backwards: Bool) -> NSRange? {
        var search = range
        let letters = CharacterSet.alphanumerics
        func isLetter(_ i: Int) -> Bool {
            guard i >= 0, i < text.length, let u = UnicodeScalar(text.character(at: i)) else { return false }
            return letters.contains(u)
        }
        while search.length > 0 {
            let r = text.range(of: word, options: backwards ? [.caseInsensitive, .backwards] : .caseInsensitive, range: search)
            guard r.location != NSNotFound else { return nil }
            if !isLetter(r.location - 1), !isLetter(NSMaxRange(r)) { return r }
            search = backwards ? NSRange(location: search.location, length: r.location - search.location)
                               : NSRange(location: NSMaxRange(r), length: NSMaxRange(search) - NSMaxRange(r))
        }
        return nil
    }
}

extension TextGrabber {
    /// A native text view: one run, starting at `start`.
    func textViewLocator(_ el: AXUIElement, text: String, start: Int) -> TextRunLocator {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return TextRunLocator(grabber: self, pid: pid, viewport: { [weak self] in self?.visibleFrame(of: el) }) {
            ([TextRunLocator.Run(element: el, start: 0, length: (text as NSString).length)], text, start)
        }
    }

    /// A web page: the text pieces of the post or message holding the start
    /// (or of the whole page for page-long reads), searching from that piece.
    func webLocator(web: AXUIElement, start marker: CFTypeRef?, element hint: AXUIElement?, wholePage: Bool) -> WordLocator {
        var pid: pid_t = 0
        AXUIElementGetPid(web, &pid)
        return TextRunLocator(grabber: self, pid: pid, viewport: { [weak self] in self?.visibleFrame(of: web) }) { [self] in
            let fromMarker = marker.flatMap { paramValue(web, "AXUIElementForTextMarker", $0) }
                .flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            // The element tapped decides the area: a paragraph's start position is
            // often reported as the end of the element before it — sometimes the
            // previous reply, whose article then hid everything being read.
            guard let startEl = hint ?? fromMarker else { return nil }
            // The area reading covers (the reply, or the whole conversation, as set);
            // failing that, the conversation area — never the whole window, whose
            // sidebar and history used up the walk before the later text.
            var root = web
            if !wholePage {
                // The same area reading uses (Settings: reply, conversation or page).
                root = readBoundary(of: startEl, scope: readScope) ?? web
                if CFEqual(root, web), readScope != .page { root = readBoundary(of: startEl, scope: .conversation) ?? web }
            }
            var runs: [TextRunLocator.Run] = []
            var text = ""
            var length = 0
            var cursor: Int?
            var visited = 0
            func walk(_ e: AXUIElement) {
                guard visited < 20000 else { return }
                visited += 1
                if cursor == nil, CFEqual(e, startEl) { cursor = length }
                if role(e) == "AXStaticText" {
                    let v = string(e, kAXValueAttribute) ?? ""
                    let n = (v as NSString).length
                    if n > 0 {
                        runs.append(.init(element: e, start: length, length: n))
                        text += v + "\n"
                        length += n + 1
                    }
                    return
                }
                for c in readingChildren(e, role: role(e)) { walk(c) }
            }
            walk(root)
            return runs.isEmpty ? nil : (runs, text, cursor ?? 0)
        }
    }

    /// Debug: the paragraph grab a tap on `el` would make (as webGrab does).
    func grabForTest(_ el: AXUIElement) -> Grab? {
        guard let web = ancestor(of: el, role: "AXWebArea"), let f = frame(el) else { return nil }
        return webGrab(.paragraph, web: web, el: el, at: CGPoint(x: f.minX + 5, y: f.minY + min(f.height / 2, 8)))
    }

    /// Debug: a web locator starting at `el`'s paragraph, plus that paragraph's text.
    func locatorForTest(_ el: AXUIElement) -> (locator: WordLocator, text: String)? {
        guard let web = ancestor(of: el, role: "AXWebArea"),
              let r = paramValue(web, "AXTextMarkerRangeForUIElement", attrElement(el, kAXParentAttribute) ?? el),
              let text = paramString(web, "AXStringForTextMarkerRange", r) else { return nil }
        return (webLocator(web: web, start: AXTextMarkerRangeCopyStartMarker(r as! AXTextMarkerRange), element: el, wholePage: false), text)
    }
}

/// Word highlight for OCR readings: Vision gives a box per printed line, and
/// each word's share of its line gives a close-enough box for the marker.
/// The boxes come from one screenshot, so they can't follow scrolling — the
/// highlight hides if the page moves.
final class OCRLocator: WordLocator, @unchecked Sendable {
    private struct Word { let norm: String; let rect: CGRect; let textAfter: String }
    private let words: [Word]
    private var cursor = 0
    private var found = false
    private var lastBox: CGRect?
    let pid: pid_t

    init(lines: [OCRLayout.Line], pid: pid_t) {
        self.pid = pid
        var out: [Word] = []
        for (li, line) in lines.enumerated() {
            let parts = line.text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let total = max(line.text.count, 1)
            var consumed = 0
            for (i, part) in parts.enumerated() {
                let share = line.rect.width / CGFloat(total)
                let x = line.rect.minX + CGFloat(consumed) * share
                let w = max(CGFloat(part.count) * share, 8)
                let after = (parts[i...].joined(separator: " ") + " " + lines[(li + 1)...].prefix(2).map(\.text).joined(separator: " ")).prefix(90)
                out.append(Word(norm: normalizedWord(part), rect: CGRect(x: x, y: line.rect.minY, width: w, height: line.rect.height),
                                textAfter: String(after)))
                consumed += part.count + 1
            }
        }
        words = out
    }

    func locate(_ phrase: String, next: String) -> CGRect? {
        let wanted = phrase.split(separator: " ").map { normalizedWord(String($0)) }.filter { !$0.isEmpty }
        guard let first = wanted.first else { return nil }
        // Until the first match, the reading may have started anywhere on the page.
        let window = found ? min(cursor + 30, words.count) : words.count
        for i in cursor..<window where words[i].norm == first {
            var box = words[i].rect
            var j = i
            for w in wanted.dropFirst() {
                guard j + 1 < words.count, words[j + 1].norm == w else { break }
                j += 1
                if abs(words[j].rect.midY - box.midY) < box.height { box = box.union(words[j].rect) }
            }
            cursor = j + 1
            found = true
            lastBox = box
            return box
        }
        return nil
    }

    func remeasure() -> CGRect? { lastBox }
    func visibleArea() -> CGRect? { nil }
    func pageBottom(below view: CGRect) -> CGFloat? { nil }
    func scrollToKeepVisible() -> Bool { false }
    var tracksScrolling: Bool { false }
    var debugView: String { "OCR boxes: \(words.count) words, cursor \(cursor)" }

    func textNear(point: CGPoint) -> String? {
        words.first { $0.rect.insetBy(dx: -1, dy: -2).contains(point) }?.textAfter
    }
}
