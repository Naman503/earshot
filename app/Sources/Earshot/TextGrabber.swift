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
}

enum GrabUnit: String { case sentence, paragraph, fromHere, window, selection }

/// Reads text from any app with the Accessibility API — including web pages in
/// Safari and Chromium browsers, via text markers — and falls back to OCR.
final class TextGrabber {
    private let system = AXUIElementCreateSystemWide()
    private var enabledPIDs = Set<pid_t>()
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

    func selection() -> Grab? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused.map({ $0 as! AXUIElement }) else { return nil }
        if let s = string(el, kAXSelectedTextAttribute), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Grab(text: s, frame: nil, source: "selection")
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
        if let g = textAreaGrab(unit, el: el, at: point) { return g }
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
        guard pid > 0, !enabledPIDs.contains(pid) else { return false }
        enabledPIDs.insert(pid)
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
        case .selection:
            return nil
        }
        guard let range, var text = paramString(web, "AXStringForTextMarkerRange", range) else { return nil }
        text = String(text.prefix(maxChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let rect = unit == .paragraph || unit == .sentence ? paramRect(web, "AXBoundsForTextMarkerRange", range) : nil
        return Grab(text: text, frame: rect, source: "web text markers")
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
        default: .all
        }
        let ns = TextUnits.range(of: u, in: full, at: r.location)
        let text = (full as NSString).substring(with: ns).trimmingCharacters(in: .whitespacesAndNewlines)
        var cf = CFRange(location: ns.location, length: ns.length)
        let rect = AXValueCreate(.cfRange, &cf).flatMap { paramRect(el, kAXBoundsForRangeParameterizedAttribute, $0) }
        return text.isEmpty ? nil : Grab(text: String(text.prefix(maxChars)), frame: rect, source: "text view")
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

    /// Whole text of the web page in the named app's front window (for --summarize-app).
    func pageText(inApp name: String) -> String? {
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
                return paramString(el, "AXStringForTextMarkerRange", range)
            }
            queue.append(contentsOf: children(el))
        }
        return nil
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
                    for unit in [GrabUnit.sentence, .paragraph, .fromHere] {
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
        if unit == .window {
            return Grab(text: blocks.map(\.text).joined(separator: "\n"), frame: windowFrame, source: "OCR")
        }
        guard let i = OCRLayout.blockIndex(at: point, in: blocks) else { return nil }
        switch unit {
        case .fromHere:
            return Grab(text: blocks[i...].map(\.text).joined(separator: "\n"), frame: blocks[i].rect, source: "OCR")
        case .sentence:
            return Grab(text: TextUnits.substring(.sentence, in: blocks[i].text, at: 0), frame: blocks[i].rect, source: "OCR")
        default:
            return Grab(text: blocks[i].text, frame: blocks[i].rect, source: "OCR")
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
