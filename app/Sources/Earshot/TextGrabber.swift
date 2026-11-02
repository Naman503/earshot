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
            // Chromium builds its tree on first request; ask again.
            usleep(150_000)
            el = element(at: point) ?? el
        }

        if let web = role(el) == "AXWebArea" ? el : ancestor(of: el, role: "AXWebArea"),
           let g = webGrab(unit, web: web, at: point) {
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
    private func enableWebAccessibility(pid: pid_t) -> Bool {
        guard pid > 0, !enabledPIDs.contains(pid) else { return false }
        enabledPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return r == .success
    }

    private func webGrab(_ unit: GrabUnit, web: AXUIElement, at point: CGPoint) -> Grab? {
        guard let marker = paramValue(web, "AXTextMarkerForPosition", axPoint(point)) else { return nil }
        var range: CFTypeRef?
        switch unit {
        case .sentence:
            range = paramValue(web, "AXSentenceTextMarkerRangeForTextMarker", marker)
        case .paragraph:
            range = paramValue(web, "AXParagraphTextMarkerRangeForTextMarker", marker)
        case .fromHere:
            let start = paramValue(web, "AXSentenceTextMarkerRangeForTextMarker", marker)
                .flatMap { paramValue(web, "AXStartTextMarkerForTextMarkerRange", $0) } ?? marker
            if let end = attr(web, "AXEndTextMarker") {
                range = paramValue(web, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
            }
        case .window:
            if let start = attr(web, "AXStartTextMarker"), let end = attr(web, "AXEndTextMarker") {
                range = paramValue(web, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray)
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
