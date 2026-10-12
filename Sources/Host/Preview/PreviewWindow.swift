import AppKit
import SwiftUI
import SystemBarKit

/// `--window`: the tab in an ordinary window, collected on its own timer by the same presenter
/// and scheduler as the menu bar. Closing the window ends the preview.
@MainActor
enum PreviewWindow {
    static func run(plugin: TabPlugin, size: CGSize, presenter: TabPresenter, cleanup: @escaping () -> Void) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(plugin.title) — SystemBar preview"
        window.contentView = NSHostingView(rootView: plugin.makeView())
        let closer = PreviewQuitOnClose(cleanup: cleanup)
        window.delegate = closer
        window.center()
        window.makeKeyAndOrderFront(nil)
        presenter.present(plugin: plugin, isVisible: true)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(closer) { app.run() }
        cleanup()
        exit(PreviewExit.ok)
    }
}

private final class PreviewQuitOnClose: NSObject, NSWindowDelegate {
    private let cleanup: () -> Void

    init(cleanup: @escaping () -> Void) {
        self.cleanup = cleanup
    }

    func windowWillClose(_ notification: Notification) {
        cleanup()
        exit(PreviewExit.ok)
    }
}
