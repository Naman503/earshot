import ApplicationServices

/// Text dump of an accessibility subtree, for debugging.
enum AXDump {
    static func tree(_ root: AXUIElement, maxDepth: Int = 14) -> String {
        var out: [String] = []
        func attr(_ el: AXUIElement, _ name: String) -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v else { return nil }
            if let s = v as? String { return s.isEmpty ? nil : s }
            return nil
        }
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth <= maxDepth, out.count < 400 else { return }
            let fields = ["AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXRoleDescription"]
                .compactMap { k in attr(el, k).map { "\(k.dropFirst(2))=\($0.prefix(120))" } }
            out.append(String(repeating: "  ", count: depth) + fields.joined(separator: " "))
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v)
            for c in v as? [AXUIElement] ?? [] { walk(c, depth + 1) }
        }
        walk(root, 0)
        return out.joined(separator: "\n")
    }
}
