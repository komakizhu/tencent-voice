import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

@MainActor
protocol LoginItemServicing: AnyObject {
    var status: LoginItemStatus { get }

    func register() throws
    func unregister() throws
}

@MainActor
final class SystemLoginItemService: LoginItemServicing {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LoginItemManager {
    private let service: any LoginItemServicing

    init() {
        service = SystemLoginItemService()
    }

    init(service: any LoginItemServicing) {
        self.service = service
    }

    var status: LoginItemStatus {
        service.status
    }

    var isEnabled: Bool {
        status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
