import Foundation

struct SystemKeyEvent: Equatable, Sendable {
    let keyCode: UInt32
    let isDown: Bool
    let isRepeat: Bool
    let timestampNanoseconds: UInt64
    let eventTag: Int64
}

enum SystemKeyEventDecoder {
    // macOS uses subtype 8 for the system-defined media-key event whose data1
    // packs the NX special-key type into the high 16 bits and the key state into
    // bits 8...15. The built-in Mac keyboard posts F5 as illumination down
    // when the function row is configured as hardware controls.
    static let systemDefinedEventTypeRawValue: UInt32 = 14
    private static let mediaKeySubtype: Int16 = 8
    private static let illuminationDownKeyType: UInt16 = 22
    private static let keyDownState: UInt8 = 10
    private static let keyUpState: UInt8 = 11

    static func decode(
        subtype: Int16,
        data1: Int64,
        timestampNanoseconds: UInt64,
        eventTag: Int64
    ) -> SystemKeyEvent? {
        guard subtype == mediaKeySubtype else { return nil }

        let packedData = UInt32(truncatingIfNeeded: data1)
        let keyType = UInt16(packedData >> 16)
        guard keyType == illuminationDownKeyType else { return nil }

        let keyState = UInt8((packedData >> 8) & 0xFF)
        guard keyState == keyDownState || keyState == keyUpState else {
            return nil
        }

        return SystemKeyEvent(
            keyCode: Shortcut.defaultF5.keyCode,
            isDown: keyState == keyDownState,
            isRepeat: (packedData & 1) != 0,
            timestampNanoseconds: timestampNanoseconds,
            eventTag: eventTag
        )
    }
}
