// ⌘⌫ for the Worktrees bulk bar's "Move to Trash…", without a window-wide key equivalent: a local
// key monitor, installed only while the bulk bar is in a window, acts on ⌘⌫ in that window only
// when no text field or text editor is being edited (the top bar's search, a sheet's field, the
// inspector). Otherwise the key goes on to the field as usual. It only opens the existing
// confirmation; nothing is moved without confirming there.
import AppKit
import SwiftUI

struct WorktreeTrashKey: NSViewRepresentable {
    var enabled: Bool
    var action: () -> Void
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.enabled = enabled; view.action = action }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.removeMonitor() }

    /// Whether ⌘⌫ should open the confirmation: exactly ⌘ (no other modifier) and Delete, in the
    /// bar's own window, with nothing being typed in.
    static func fires(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, sameWindow: Bool, editingText: Bool) -> Bool {
        keyCode == 51 && modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command
            && sameWindow && !editingText
    }

    final class KeyView: NSView {
        var enabled = false
        var action: () -> Void = {}
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window else { return event }
                let editing = window.firstResponder is NSText || window.firstResponder is NSTextField
                guard WorktreeTrashKey.fires(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                             sameWindow: event.window === window && window.attachedSheet == nil,
                                             editingText: editing) else { return event }
                self.action()
                return nil
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
