import Foundation

struct HIDUserKeyMapping: Codable, Equatable, Sendable {
    let source: UInt64
    let destination: UInt64

    enum CodingKeys: String, CodingKey {
        case source = "HIDKeyboardModifierMappingSrc"
        case destination = "HIDKeyboardModifierMappingDst"
    }
}

struct HIDMappingCommandResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

/// Temporarily maps Apple's built-in dictation key to the standard F5 key.
///
/// The mapping is persisted only as ownership metadata so a later launch can
/// restore the exact mapping set that existed before Rime Voice changed it.
/// An existing mapping for the same source is never replaced.
final class NativeF5Remapper {
    static let voiceCommandSource: UInt64 = 0xC000000CF
    static let standardF5Destination: UInt64 = 0x70000003E

    private let defaults: UserDefaults
    private let runCommand: ([String]) -> HIDMappingCommandResult
    private var originalMappings: [HIDUserKeyMapping]?
    private var appliedMappings: [HIDUserKeyMapping]?
    private let ownershipKey = "nativeF5Remapper.ownership.v1"

    init(
        defaults: UserDefaults = .standard,
        runCommand: @escaping ([String]) -> HIDMappingCommandResult = NativeF5Remapper.runSystemCommand
    ) {
        self.defaults = defaults
        self.runCommand = runCommand
    }

    @discardableResult
    func synchronize(shouldApply: Bool) -> Bool {
        if shouldApply {
            return applyIfNeeded()
        }

        return restoreIfOwned()
    }

    @discardableResult
    func restoreIfOwned() -> Bool {
        loadOwnershipIfNeeded()
        guard let originalMappings, let appliedMappings else { return true }
        guard let currentMappings = readMappings() else {
            return false
        }
        guard currentMappings == appliedMappings else {
            // Another tool changed the mapping. Do not overwrite that change.
            self.originalMappings = nil
            self.appliedMappings = nil
            defaults.removeObject(forKey: ownershipKey)
            return true
        }

        guard writeMappings(originalMappings) else {
            return false
        }
        self.originalMappings = nil
        self.appliedMappings = nil
        defaults.removeObject(forKey: ownershipKey)
        return true
    }

    private func applyIfNeeded() -> Bool {
        loadOwnershipIfNeeded()
        guard let currentMappings = readMappings() else { return false }
        if let appliedMappings, currentMappings == appliedMappings { return true }
        // Sleep, session switches and other keyboard tools can remove the
        // mapping while this process still holds its old ownership snapshot.
        // Rebase on the actual current mappings, preserving unrelated edits.
        originalMappings = nil
        appliedMappings = nil
        defaults.removeObject(forKey: ownershipKey)
        if let existingVoiceCommand = currentMappings.first(where: {
            $0.source == Self.voiceCommandSource
        }) {
            // Respect a mapping owned by another tool. Replacing it would make
            // the user's existing keyboard configuration unrecoverable here.
            return existingVoiceCommand.destination == Self.standardF5Destination
        }

        let desiredMappings = currentMappings + [
            HIDUserKeyMapping(
                source: Self.voiceCommandSource,
                destination: Self.standardF5Destination
            )
        ]
        guard writeMappings(desiredMappings) else { return false }

        originalMappings = currentMappings
        appliedMappings = desiredMappings
        saveOwnership()
        return true
    }

    private func loadOwnershipIfNeeded() {
        guard originalMappings == nil, appliedMappings == nil else { return }
        guard
            let data = defaults.data(forKey: ownershipKey),
            let ownership = try? JSONDecoder().decode(OwnershipState.self, from: data)
        else {
            return
        }
        originalMappings = ownership.originalMappings
        appliedMappings = ownership.appliedMappings
    }

    private func saveOwnership() {
        guard
            let originalMappings,
            let appliedMappings,
            let data = try? JSONEncoder().encode(
                OwnershipState(
                    originalMappings: originalMappings,
                    appliedMappings: appliedMappings
                )
            )
        else {
            return
        }
        defaults.set(data, forKey: ownershipKey)
    }

    private func readMappings() -> [HIDUserKeyMapping]? {
        let result = runCommand(["property", "--get", "UserKeyMapping"])
        guard result.status == 0 else { return nil }
        return Self.parseMappings(result.standardOutput)
    }

    private func writeMappings(_ mappings: [HIDUserKeyMapping]) -> Bool {
        let payload = UserKeyMappingPayload(userKeyMapping: mappings)
        guard
            let data = try? JSONEncoder().encode(payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return false
        }

        return runCommand(["property", "--set", json]).status == 0
    }

    static func parseMappings(_ output: String) -> [HIDUserKeyMapping] {
        output
            .split(separator: "}")
            .compactMap { block in
                guard
                    let source = value(named: "HIDKeyboardModifierMappingSrc", in: block),
                    let destination = value(named: "HIDKeyboardModifierMappingDst", in: block)
                else {
                    return nil
                }
                return HIDUserKeyMapping(source: source, destination: destination)
            }
    }

    private static func value(named name: String, in block: Substring) -> UInt64? {
        guard
            let keyRange = block.range(of: name),
            let equals = block[keyRange.upperBound...].firstIndex(of: "="),
            let semicolon = block[equals...].firstIndex(of: ";")
        else {
            return nil
        }

        let value = block[block.index(after: equals)..<semicolon]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return UInt64(value)
    }

    private static func runSystemCommand(arguments: [String]) -> HIDMappingCommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return HIDMappingCommandResult(
                status: -1,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        return HIDMappingCommandResult(
            status: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }
}

private struct UserKeyMappingPayload: Codable, Sendable {
    let userKeyMapping: [HIDUserKeyMapping]

    enum CodingKeys: String, CodingKey {
        case userKeyMapping = "UserKeyMapping"
    }
}

private struct OwnershipState: Codable, Sendable {
    let originalMappings: [HIDUserKeyMapping]
    let appliedMappings: [HIDUserKeyMapping]
}
