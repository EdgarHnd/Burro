// Open at login through ServiceManagement's main-app login item. macOS's status is the only record:
// it's read when Settings or the Today menu shows it and whenever Burro becomes active again (you can
// change it in System Settings › General › Login Items), never saved in Burro's defaults. Nothing is
// registered until you turn it on.
import AppKit
import Observation
import ServiceManagement
import BurroCore

@MainActor @Observable final class LoginItemStore {
    private(set) var state: LoginItemState
    /// The last register or unregister that threw, until the next try or a status change.
    private(set) var failure: String?
    var presentation: LoginItemPresentation { LoginItemPresentation(state: state, failure: failure) }

    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    init() {
        state = Self.read()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Reads the status from macOS again. A changed status clears an old failure.
    func refresh() {
        let current = Self.read()
        if current != state { failure = nil; state = current }
    }

    /// Registers or unregisters Burro, then reads the status back. Returns the failure line if it threw.
    @discardableResult
    func setEnabled(_ on: Bool) -> String? {
        failure = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = LoginItemPresentation.failure(turningOn: on, reason: error.localizedDescription)
        }
        state = Self.read()
        return failure
    }

    /// Opens System Settings › General › Login Items, where a pending login item is approved.
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static func read() -> LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
}
