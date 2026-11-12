// Launch at login via SMAppService.mainApp.
import ServiceManagement

@MainActor
enum LoginItemService {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registers or unregisters Ting. Returns a short error message on failure.
    static func set(_ enabled: Bool) -> String? {
        guard enabled != isEnabled else { return nil }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Launch at login: \(error.localizedDescription)"
        }
    }
}
