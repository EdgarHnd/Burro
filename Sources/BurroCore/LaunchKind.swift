// How Burro was launched, read from the launch Apple event: an open-application event
// (kCoreEventClass 'aevt' / kAEOpenApplication 'oapp') whose keyAEPropData parameter is
// keyAELaunchedAsLogInItem ('lgit') means macOS opened it as a login item. Then Burro starts
// quietly (notch and menu bar only, no main window); anything else is a normal launch.
import Foundation

public enum LaunchKind: Equatable, Sendable {
    case normal, loginItem

    /// Four-character codes from AppleEvents.h and AERegistry.h.
    public static let coreEventClass = fourCharCode("aevt")
    public static let openApplication = fourCharCode("oapp")
    public static let propData = fourCharCode("prdt")
    public static let launchedAsLoginItem = fourCharCode("lgit")

    /// `propDataEnum` is the event's keyAEPropData parameter as an enum code, when present;
    /// `hasLoginItemParameter` is whether the event carries a 'lgit' parameter of its own.
    public static func classify(eventClass: UInt32?, eventID: UInt32?, propDataEnum: UInt32?, hasLoginItemParameter: Bool = false) -> LaunchKind {
        guard eventClass == coreEventClass, eventID == openApplication else { return .normal }
        return propDataEnum == launchedAsLoginItem || hasLoginItemParameter ? .loginItem : .normal
    }

    /// Combines what was read at will-finish and did-finish launching: either one saying login wins.
    public static func combine(_ kinds: LaunchKind?...) -> LaunchKind {
        kinds.contains(.loginItem) ? .loginItem : .normal
    }

    public static func fourCharCode(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}
