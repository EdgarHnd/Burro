// Hand the dashboard's actual window to the notch controller so agent clicks reuse it.
import SwiftUI
import AppKit

struct WindowProbe: NSViewRepresentable {
    var onAttach: (NSWindow) -> Void
    var onVisibilityChange: ((ObjectIdentifier, Bool) -> Void)? = nil
    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(); view.onAttach = onAttach; view.onVisibilityChange = onVisibilityChange; return view
    }
    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onAttach = onAttach; nsView.onVisibilityChange = onVisibilityChange
    }
    final class ProbeView: NSView {
        var onAttach: ((NSWindow) -> Void)?
        var onVisibilityChange: ((ObjectIdentifier, Bool) -> Void)?
        private weak var observedWindow: NSWindow?
        deinit { NotificationCenter.default.removeObserver(self) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observedWindow { onVisibilityChange?(ObjectIdentifier(observedWindow), false) }
            NotificationCenter.default.removeObserver(self)
            observedWindow = window
            if let window {
                onAttach?(window)
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: name, object: window)
                }
                visibilityChanged(nil)
            }
        }
        @objc private func visibilityChanged(_ notification: Notification?) {
            guard let window = observedWindow else { return }
            let visible = notification?.name != NSWindow.willCloseNotification && window.isVisible
                && !window.isMiniaturized && window.occlusionState.contains(.visible)
            onVisibilityChange?(ObjectIdentifier(window), visible)
        }
    }
}
