import XCTest
@testable import TencentVoiceMVP

@MainActor
final class LoginItemTests: XCTestCase {
    func testEnablingLoginItemRegistersTheService() throws {
        let service = FakeLoginItemService()
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertTrue(manager.isEnabled)
    }

    func testDisablingLoginItemUnregistersTheService() throws {
        let service = FakeLoginItemService(status: .enabled)
        let manager = LoginItemManager(service: service)

        try manager.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(manager.isEnabled)
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    var status: LoginItemStatus

    init(status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}
