// Open at login: what the Settings toggle and the Today menu show for macOS's login-item status.
// The app maps ServiceManagement's status into `LoginItemState`; macOS stays the source of truth,
// so nothing here is saved.
import Foundation

/// macOS's login-item status for Burro, in Burro's own terms.
public enum LoginItemState: Sendable, Equatable {
    /// Burro opens when you log in.
    case enabled
    /// Burro is not a login item (the default).
    case notRegistered
    /// Burro asked to open at login and waits for your approval in System Settings › General › Login Items.
    case requiresApproval
    /// macOS can't find this copy of Burro as an app it can open at login.
    case notFound
}

public struct LoginItemPresentation: Sendable, Equatable {
    /// The toggle is on: Burro opens at login, or asked to and waits for your approval.
    public var isOn: Bool
    /// Show a button that opens System Settings › General › Login Items.
    public var needsApproval: Bool
    /// One short line under the toggle, or nil when there's nothing to say.
    public var note: String?
    /// The note reports a problem rather than a step to take.
    public var isProblem: Bool

    /// `failure` is the message from the last register or unregister that threw; it is shown instead
    /// of the status note, and the toggle still follows the status.
    public init(state: LoginItemState, failure: String? = nil) {
        isOn = state == .enabled || state == .requiresApproval
        needsApproval = state == .requiresApproval
        if let failure {
            note = failure
            isProblem = true
            return
        }
        switch state {
        case .enabled, .notRegistered:
            note = nil
            isProblem = false
        case .requiresApproval:
            note = "Waiting for your approval in System Settings › General › Login Items."
            isProblem = false
        case .notFound:
            note = "macOS can't find this copy of Burro to open at login. Open Burro from its app in Applications or dist, then try again."
            isProblem = true
        }
    }

    /// The line shown when turning it on or off throws.
    public static func failure(turningOn: Bool, reason: String) -> String {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = turningOn ? "Couldn't add Burro to your login items" : "Couldn't remove Burro from your login items"
        return reason.isEmpty ? "\(lead)." : "\(lead): \(reason)"
    }
}
