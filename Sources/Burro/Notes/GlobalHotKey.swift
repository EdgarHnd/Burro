// A system-wide keyboard shortcut through Carbon's hot key API: no Accessibility or Input
// Monitoring permission, and Burro sees only the shortcut itself, never other keystrokes.
import Carbon.HIToolbox
import Foundation

@MainActor final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// Registers the shortcut, or returns nil if macOS refuses it (usually another app has it).
    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, action: @escaping () -> Void) {
        Self.installHandler()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: 0x4255_524F /* BURO */, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        self.ref = ref
        self.id = id
        Self.actions[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKey = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            let id = hotKey.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.actions[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension GlobalHotKey {
    /// ⌥P, the shortcut Raycast Notes uses.
    static let notesKeyCode = UInt32(kVK_ANSI_P)
    static let notesModifiers = UInt32(optionKey)
}
