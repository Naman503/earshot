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
}

enum GrabUnit: String { case sentence, paragraph, fromHere, section, visible, window, selection }

/// Reads text from any app with the Accessibility API — including web pages in
/// Safari and Chromium browsers, via text markers — and falls back to OCR.
final class TextGrabber {
    private let system = AXUIElementCreateSystemWide()
    private var enabledPIDs = Set<pid_t>()
    private let lock = NSLock()
    private let maxChars = 60_000

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
            let rect = attr(el, kAXSelectedTextRangeAttribute).flatMap { paramRect(el, kAXBoundsForRangeParameterizedAttribute, $0) }
            return Grab(text: s, frame: rect, source: "selection")
        }
        // Web content: the selection lives on the web area as a text-marker range.
        if let web = ancestor(of: el, role: "AXWebArea") ?? (role(el) == "AXWebArea" ? el : nil),
           let range = attr(web, "AXSelectedTextMarkerRange"),
           let s = paramString(web, "AXStringForTextMarkerRange", range), !s.isEmpty {
            return Grab(text: s, frame: paramRect(web, "AXBoundsForTextMarkerRange", range), source: "web selection")
        }
        return nil
    }

    // MARK: Accessibility

    private func axGrab(_ unit: GrabUnit, at point: CGPoint) -> Grab? {
        guard var el = element(at: point) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if enableWebAccessibility(pid: pid) {
            // Chromium builds its tree on first request; wait until web content shows up.
            for _ in 0..<8 {
                usleep(100_000)
                el = element(at: point) ?? el
                if role(el) != "AXGroup" || ancestor(of: el, role: "AXWebArea") != nil { break }
            }
        }

        if let web = role(el) == "AXWebArea" ? el : ancestor(of: el, role: "AXWebArea"),
           let g = webGrab(unit, web: web, el: el, at: point) {
            return g
        }
        // Outside web pages, "visible" is exactly what OCR sees.
        if unit == .visible { return nil }
        if let g = textAreaGrab(unit, el: el, at: point) { return g }
        if unit == .section { return nil }
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
        guard pid > 0, lock.withLock({ enabledPIDs.insert(pid).inserted }) else { return false }
        let app = AXUIElementCreateApplication(pid)
        let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return r == .success
    }

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
            if let end = attr(web, "AXEndTextMarker") {
                range = AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
            }
        case .window:
            if let start = attr(web, "AXStartTextMarker"), let end = attr(web, "AXEndTextMarker") {
                range = AXTextMarkerRangeCreate(nil, start as! AXTextMarker, end as! AXTextMarker)
            }
        case .section:
            // Join the section's blocks with line breaks so a heading isn't glued to its text.
            guard let (r, text) = sectionRange(of: el, web: web) else { return nil }
            return Grab(text: String(text.prefix(maxChars)), frame: paramRect(web, "AXBoundsForTextMarkerRange", r), source: "web section")
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
        if unit == .paragraph, let n = blockNeighbours(of: el) {
            grab.before = n.before
            grab.after = n.after
        } else if unit == .paragraph, CFGetTypeID(range) == AXTextMarkerRangeGetTypeID(),
           let docStart = attr(web, "AXStartTextMarker"), let docEnd = attr(web, "AXEndTextMarker") {
            let r = range as! AXTextMarkerRange
            grab.before = paramString(web, "AXStringForTextMarkerRange",
                                      AXTextMarkerRangeCreate(nil, docStart as! AXTextMarker, AXTextMarkerRangeCopyStartMarker(r))).map { String($0.suffix(30_000)) }
            grab.after = paramString(web, "AXStringForTextMarkerRange",
                                     AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyEndMarker(r), docEnd as! AXTextMarker)).map { String($0.prefix(maxChars)) }
        }
        return grab
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
    func blockNeighbours(of el: AXUIElement) -> (before: String, after: String)? {
        var boundary: AXUIElement?
        var cur = el
        for _ in 0..<40 {
            guard let parent = attrElement(cur, kAXParentAttribute) else { break }
            let sub = string(parent, kAXSubroleAttribute)
            if sub == "AXDocumentArticle" || sub == "AXLandmarkMain" || role(parent) == "AXWebArea" { boundary = parent; break }
            cur = parent
        }
        guard let boundary else { return nil }
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
            if role(e) == "AXListMarker" || skip.contains(role(e) ?? "") { return "" }
            return children(e).map { text($0, holds: &holds) }.joined()
        }
        func walk(_ e: AXUIElement) {
            guard visited < 6000 else { return }
            visited += 1
            let r = role(e) ?? ""
            if skip.contains(r) { return }
            let kids = children(e)
            // A block that has its own text runs is one paragraph, whatever
            // inline groups (bold, code, links) sit between those runs.
            let ownText = kids.contains { role($0) == "AXStaticText" && !(string($0, kAXValueAttribute) ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
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
        guard visited < 6000, let i = current else { return nil }
        return (blocks[..<i].joined(separator: "\n"), blocks[(i + 1)...].joined(separator: "\n"))
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
            for c in children(el) { walk(c) }
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
            for c in children(el) { walk(c, depth: depth + 1) }
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
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { return nil }
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
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name && $0.activationPolicy == .regular }) else {
            Log.write("findText: no app \(name)"); return nil
        }
        enableWebAccessibility(pid: app.processIdentifier)
        usleep(500_000)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let wins = (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var found: AXUIElement?
        var visited = 0
        func walk(_ el: AXUIElement) {
            guard found == nil, visited < 40000 else { return }
            visited += 1
            if role(el) == "AXStaticText", let v = string(el, kAXValueAttribute) {
                if v.contains(needle) { found = el }
                return
            }
            for c in children(el) { walk(c) }
        }
        wins.forEach(walk)
        Log.write("findText: \(wins.count) windows, visited \(visited)")
        return found
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
        guard let (image, windowFrame) = await captureWindow(at: point) else { return nil }
        let lines = await recognize(image, in: windowFrame)
        let blocks = OCRLayout.blocks(lines)
        guard !blocks.isEmpty else { return nil }
        if unit == .window || unit == .visible {
            return Grab(text: blocks.map(\.text).joined(separator: "\n"), frame: windowFrame, source: "OCR")
        }
        guard let i = OCRLayout.blockIndex(at: point, in: blocks) else { return nil }
        switch unit {
        case .fromHere:
            return Grab(text: blocks[i...].map(\.text).joined(separator: "\n"), frame: blocks[i].rect, source: "OCR")
        case .section:
            let r = OCRLayout.sectionRange(blocks, around: i)
            let rect = blocks[r].dropFirst().reduce(blocks[r.lowerBound].rect) { $0.union($1.rect) }
            return Grab(text: blocks[r].map(\.text).joined(separator: "\n"), frame: rect, source: "OCR")
        case .sentence:
            return Grab(text: TextUnits.substring(.sentence, in: blocks[i].text, at: 0), frame: blocks[i].rect, source: "OCR")
        default:
            return Grab(text: blocks[i].text, frame: blocks[i].rect, source: "OCR",
                        before: blocks[..<i].map(\.text).joined(separator: "\n"),
                        after: blocks[(i + 1)...].map(\.text).joined(separator: "\n"))
        }
    }

    /// Screenshot of the topmost normal window under the pointer.
    private func captureWindow(at point: CGPoint) async -> (CGImage, CGRect)? {
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
            return (image, window.frame)
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
        return AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success ? el : nil
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
    private func role(_ el: AXUIElement) -> String? { string(el, kAXRoleAttribute) }
    private func children(_ el: AXUIElement) -> [AXUIElement] { attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

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
