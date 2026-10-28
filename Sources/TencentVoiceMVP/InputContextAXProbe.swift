import ApplicationServices
import Foundation
import Carbon

// References are used only on the recorder's serial queue; no AX writes are performed.
struct InputContextElementReference: @unchecked Sendable {
    let element: AXUIElement?
}

protocol InputContextSampling: AnyObject, Sendable {
    func sample(pid: pid_t, target: AXUIElement?, includeEditors: Bool) -> [String: String]
}

struct InputContextEditorWalk<Node> {
    private var pending: [(Node, Int)]
    private(set) var visitedCount = 0
    private(set) var truncated = false
    private let nodeLimit: Int
    private let depthLimit: Int

    init(root: Node, nodeLimit: Int = 160, depthLimit: Int = 64) {
        pending = [(root, 0)]
        self.nodeLimit = nodeLimit
        self.depthLimit = depthLimit
    }

    // Visit later window branches first: Electron composers usually follow long conversation content.
    mutating func next(children: (Node) -> [Node]) -> Node? {
        guard !pending.isEmpty else { return nil }
        guard visitedCount < nodeLimit else { truncated = true; return nil }
        let (node, depth) = pending.removeLast()
        visitedCount += 1
        let descendants = children(node)
        if depth < depthLimit {
            let remaining = max(0, nodeLimit - visitedCount - pending.count)
            if descendants.count > remaining { truncated = true }
            pending.append(contentsOf: descendants.suffix(remaining).map { ($0, depth + 1) })
        } else if !descendants.isEmpty {
            truncated = true
        }
        return node
    }
}

// All queries are bounded and run off the input/UI thread. Text is discarded after
// computing UTF16 length; titles, placeholders, values and selected text are never logged.
final class InputContextAXProbe: InputContextSampling, @unchecked Sendable {
    private var identities: [(AXUIElement, Int)] = []
    private var nextID = 0
    private var deadline = Date.distantPast
    private var status: [String: String] = [:]
    private let isTrusted: () -> Bool
    private let secureInputActive: () -> Bool
    private let readAttribute: ((String, AXUIElement) -> (AXError, CFTypeRef?))?

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         secureInputActive: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         readAttribute: ((String, AXUIElement) -> (AXError, CFTypeRef?))? = nil) {
        self.isTrusted = isTrusted
        self.secureInputActive = secureInputActive
        self.readAttribute = readAttribute
    }

    func sample(pid: pid_t, target: AXUIElement? = nil, includeEditors: Bool = false) -> [String: String] {
        guard isTrusted() else { return ["axAvailable": "false"] }
        let start = Date()
        deadline = start.addingTimeInterval(0.25)
        status = [:]
        let app = AXUIElementCreateApplication(pid)
        var result = ["axAvailable": "true"]
        let window = element("AXFocusedWindow", in: app)
        if let window { result["windowID"] = String(identity(window)) }
        let focus = element("AXFocusedUIElement", in: app)
        let systemFocus = element("AXFocusedUIElement", in: AXUIElementCreateSystemWide())
        result["focusAvailable"] = String(focus != nil)
        if let focus {
            result["focusID"] = String(identity(focus))
            result.merge(metadata(focus)) { _, new in new }
        }
        if let structureNode = target ?? focus {
            result.merge(structureMetadata(structureNode).mapKeys { "structure." + $0 }) { _, new in new }
        }
        if let systemFocus {
            result["systemFocusID"] = String(identity(systemFocus))
            result.merge(metadata(systemFocus).mapKeys { "systemFocus." + $0 }) { _, new in new }
        }
        if let target {
            result["targetID"] = String(identity(target))
            result["targetMatchesAppFocus"] = String(focus.map { CFEqual($0, target) } ?? false)
            result["targetMatchesSystemFocus"] = String(systemFocus.map { CFEqual($0, target) } ?? false)
            // Inspect independent read handles, never change the writer's AX handle timeout.
            if let focus, CFEqual(focus, target) {
                result.merge(metadata(focus).mapKeys { "target." + $0 }) { _, new in new }
            }
        }
        if includeEditors, let window {
            var walk = InputContextEditorWalk(root: window)
            var seen: [AXUIElement] = []
            var editors = 0
            while Date() < deadline, let node = walk.next(children: { node in
                guard !seen.contains(where: { CFEqual($0, node) }) else { return [] }
                seen.append(node)
                return attribute("AXChildren", in: node) as? [AXUIElement] ?? []
            }) {
                let role = attribute("AXRole", in: node) as? String
                guard role == "AXTextArea" || role == "AXTextField" || role == "AXSearchField" else { continue }
                let prefix = "editor\(editors)."
                result[prefix + "elementID"] = String(identity(node))
                let details = metadata(node)
                result.merge(details.mapKeys { prefix + $0 }) { _, new in new }
                if let target, CFEqual(node, target) {
                    result.merge(details.mapKeys { "target." + $0 }) { _, new in new }
                }
                editors += 1
                if editors >= 12 { result["editorLimitReached"] = "true"; break }
            }
            result["editorCount"] = String(editors)
            result["visitedNodeCount"] = String(walk.visitedCount)
            result["editorTraversalTruncated"] = String(walk.truncated || Date() >= deadline || editors >= 12)
        }
        result["probeElapsedMilliseconds"] = String(Int(Date().timeIntervalSince(start) * 1000))
        result["probeBudgetExceeded"] = String(Date() >= deadline)
        result.merge(status) { _, new in new }
        return result
    }

    private func metadata(_ node: AXUIElement) -> [String: String] {
        var result: [String: String] = [:]
        result["role"] = attribute("AXRole", in: node) as? String
        result["subrole"] = attribute("AXSubrole", in: node) as? String
        var pid: pid_t = 0
        if AXUIElementGetPid(node, &pid) == .success { result["focusOwnerPID"] = String(pid) }
        for name in ["AXFocused", "AXEnabled"] {
            if let value = attribute(name, in: node) as? NSNumber { result[name] = value.stringValue }
        }
        // If the secure-field check cannot be read, do not query its text or selection.
        guard !secureInputActive(), result["subrole"] != "AXSecureTextField",
              result["role"] == "AXTextArea" || result["subrole"] != nil else { return result }
        if let count = attribute("AXNumberOfCharacters", in: node) as? NSNumber { result["documentLength"] = count.stringValue }
        if let value = attribute("AXValue", in: node) as? String { result["axValueLengthUTF16"] = String(value.utf16.count) }
        if let value = attribute("AXSelectedTextRange", in: node), CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) {
                result["selectionLocation"] = String(range.location)
                result["selectionLength"] = String(range.length)
            }
        }
        if let value = attribute("AXPosition", in: node), CFGetTypeID(value) == AXValueGetTypeID() {
            var point = CGPoint.zero
            if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) {
                result["screenX"] = String(Int(point.x.rounded()))
                result["screenY"] = String(Int(point.y.rounded()))
            }
        }
        if let value = attribute("AXSize", in: node), CFGetTypeID(value) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) {
                result["width"] = String(Int(size.width.rounded()))
                result["height"] = String(Int(size.height.rounded()))
            }
        }
        return result
    }

    /// Collect only bounded AX role/identity evidence around the focused
    /// editor. The inventory intentionally excludes AXValue and selected text:
    /// it is useful for later paragraph/node calibration without recording
    /// user正文. A role path is evidence about the accessibility tree, not a
    /// paragraph model; callers must keep `structureEvidence` unknown until a
    /// real editor observation establishes that mapping.
    private func structureMetadata(_ start: AXUIElement) -> [String: String] {
        let limit = 32
        var current = start
        var visited: [AXUIElement] = []
        var roles: [String] = []
        var subroles: [String] = []
        var status = "complete"

        while roles.count < limit, Date() < deadline {
            if visited.contains(where: { CFEqual($0, current) }) {
                status = "cycle"
                break
            }
            visited.append(current)
            guard let role = attribute("AXRole", in: current) as? String else {
                status = "read_failure"
                break
            }
            roles.append(role)
            subroles.append(attribute("AXSubrole", in: current) as? String ?? "unknown")
            guard let parent = element("AXParent", in: current) else {
                break
            }
            current = parent
        }

        if roles.count >= limit || Date() >= deadline {
            status = "truncated"
        }
        return [
            "ancestorCount": String(roles.count),
            "ancestorRoles": roles.joined(separator: ">"),
            "ancestorSubroles": subroles.joined(separator: ">"),
            "traversalStatus": status,
            "evidence": "unknown"
        ]
    }

    private func identity(_ node: AXUIElement) -> Int {
        if let existing = identities.first(where: { CFEqual($0.0, node) }) { return existing.1 }
        nextID += 1
        identities.append((node, nextID))
        if identities.count > 512 { identities.removeFirst() }
        return nextID
    }

    private func attribute(_ name: String, in node: AXUIElement) -> CFTypeRef? {
        guard Date() < deadline else { status["queryBudgetExceeded"] = "true"; return nil }
        var value: CFTypeRef?
        let code: AXError
        if let readAttribute {
            (code, value) = readAttribute(name, node)
        } else {
            AXUIElementSetMessagingTimeout(node, 0.03)
            code = AXUIElementCopyAttributeValue(node, name as CFString, &value)
        }
        if code != .success { status["element\(identity(node)).\(name).status"] = String(code.rawValue) }
        return code == .success ? value : nil
    }

    private func element(_ name: String, in node: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, in: node), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

private extension Dictionary where Key == String, Value == String {
    func mapKeys(_ transform: (String) -> String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
