import Foundation
import XCTest
@testable import TencentVoiceMVP

final class NativeF5RemapperTests: XCTestCase {
    func testRecoversRemovedMappingAndPreservesNewUnrelatedMappings() throws {
        let suite = "NativeF5RemapperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var mappings: [HIDUserKeyMapping] = []
        let remapper = NativeF5Remapper(defaults: defaults) { args in
            if args == ["property", "--get", "UserKeyMapping"] {
                let output = mappings.map {
                    "{ HIDKeyboardModifierMappingSrc = \($0.source); HIDKeyboardModifierMappingDst = \($0.destination); }"
                }.joined()
                return HIDMappingCommandResult(status: 0, standardOutput: output, standardError: "")
            }
            struct Payload: Decodable { let UserKeyMapping: [HIDUserKeyMapping] }
            do {
                mappings = try JSONDecoder().decode(Payload.self, from: Data(args[2].utf8)).UserKeyMapping
                return HIDMappingCommandResult(status: 0, standardOutput: "", standardError: "")
            } catch {
                XCTFail("Invalid mapping payload: \(error)")
                return HIDMappingCommandResult(status: 1, standardOutput: "", standardError: "")
            }
        }
        XCTAssertTrue(remapper.synchronize(shouldApply: true))
        mappings = [] // System removed the mapping while the App remained open.
        XCTAssertTrue(remapper.synchronize(shouldApply: true))
        XCTAssertEqual(mappings.count, 1)
        let unrelated = HIDUserKeyMapping(source: 30064771073, destination: 30064771072)
        mappings = [unrelated]
        XCTAssertTrue(remapper.synchronize(shouldApply: true))
        XCTAssertTrue(mappings.contains(unrelated))
        XCTAssertEqual(mappings.count, 2)
        XCTAssertTrue(remapper.restoreIfOwned())
        XCTAssertEqual(mappings, [unrelated])
        XCTAssertTrue(remapper.synchronize(shouldApply: true))
        let conflict = HIDUserKeyMapping(source: NativeF5Remapper.voiceCommandSource, destination: 1)
        mappings = [unrelated, conflict]
        XCTAssertFalse(remapper.synchronize(shouldApply: true))
        XCTAssertEqual(mappings, [unrelated, conflict])
    }

    func testUsesAppleVoiceCommandAsSourceAndStandardF5AsDestination() {
        XCTAssertEqual(NativeF5Remapper.voiceCommandSource, 0xC000000CF)
        XCTAssertEqual(NativeF5Remapper.standardF5Destination, 0x70000003E)
    }

    func testParsesHIDUtilMappingOutput() {
        let output = """
        UserKeyMapping:(
                {
                HIDKeyboardModifierMappingDst = 30064771072;
                HIDKeyboardModifierMappingSrc = 30064771073;
            },
                {
                HIDKeyboardModifierMappingDst = 30064771134;
                HIDKeyboardModifierMappingSrc = 51539607759;
            }
        )
        """

        XCTAssertEqual(
            NativeF5Remapper.parseMappings(output),
            [
                HIDUserKeyMapping(source: 30064771073, destination: 30064771072),
                HIDUserKeyMapping(source: 51539607759, destination: 30064771134)
            ]
        )
    }

    func testAddsAndRestoresOnlyItsOwnMapping() {
        let suiteName = "NativeF5RemapperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var currentOutput = "(null)"
        var setPayloads: [String] = []
        let remapper = NativeF5Remapper(defaults: defaults) { arguments in
            if arguments == ["property", "--get", "UserKeyMapping"] {
                return HIDMappingCommandResult(status: 0, standardOutput: currentOutput, standardError: "")
            }

            guard arguments.count == 3, arguments[0] == "property", arguments[1] == "--set" else {
                XCTFail("Unexpected hidutil arguments")
                return HIDMappingCommandResult(status: 1, standardOutput: "", standardError: "bad args")
            }
            setPayloads.append(arguments[2])
            currentOutput = arguments[2].contains("51539607759")
                ? """
                  (
                      {
                      HIDKeyboardModifierMappingDst = 30064771134;
                      HIDKeyboardModifierMappingSrc = 51539607759;
                  }
                  )
                  """
                : "(null)"
            return HIDMappingCommandResult(status: 0, standardOutput: "", standardError: "")
        }

        XCTAssertTrue(remapper.synchronize(shouldApply: true))
        XCTAssertEqual(setPayloads.count, 1)
        XCTAssertTrue(setPayloads[0].contains("51539607759"))
        XCTAssertTrue(setPayloads[0].contains("30064771134"))

        XCTAssertTrue(remapper.synchronize(shouldApply: false))
        XCTAssertEqual(setPayloads.count, 2)
        XCTAssertTrue(setPayloads[1].contains("UserKeyMapping"))
    }

    func testDoesNotReplaceAnExistingVoiceCommandMapping() {
        let suiteName = "NativeF5RemapperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let remapper = NativeF5Remapper(defaults: defaults) { arguments in
            guard arguments == ["property", "--get", "UserKeyMapping"] else {
                XCTFail("The remapper must not overwrite another tool's mapping")
                return HIDMappingCommandResult(status: 1, standardOutput: "", standardError: "")
            }
            return HIDMappingCommandResult(
                status: 0,
                standardOutput: """
                (
                    {
                    HIDKeyboardModifierMappingDst = 30064771072;
                    HIDKeyboardModifierMappingSrc = 51539607759;
                }
                )
                """,
                standardError: ""
            )
        }

        XCTAssertFalse(remapper.synchronize(shouldApply: true))
    }
}
