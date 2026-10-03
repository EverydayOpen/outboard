import OutboardCore
import ServiceManagement

/// "Start Outboard at login": the main app as a login item, nothing else (`SMAppService.mainApp`; never an agent, a daemon or a
/// helper). It is registered only after the user says yes on the first move. Without it the guard only runs while Outboard is open,
/// and the app says so. After an update the status is read again and reported plainly, including `requiresApproval` and `notFound`
/// (an ad-hoc build replaced by a signed one can lose the item). VERIFY on 13, 15, 26 and 27.
enum LoginItem {
    static var state: LoginItemState { map(SMAppService.mainApp.status) }

    static func map(_ status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unavailable
        }
    }

    /// Registers or unregisters and returns the state afterwards. A call that throws and leaves the item unregistered is `unavailable`.
    static func set(_ enabled: Bool) -> LoginItemState {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let after = state
            return enabled && after == .notRegistered ? .unavailable : after
        }
        return state
    }
}
