import AppKit
import SwiftUI

/// Creates and tears down the fullscreen borderless lock screen window and starts
/// / stops polling in step with its visibility.
@MainActor
final class LockScreenWindowController {
    private let model: NowPlayingModel
    private var window: LockScreenWindow?

    init(model: NowPlayingModel) {
        self.model = model
    }

    func toggle() {
        window == nil ? show() : hide()
    }

    func show() {
        guard window == nil else { return }
        guard let screen = NSScreen.main else { return }

        let window = LockScreenWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // NSWindow defaults to isReleasedWhenClosed = true; combined with our own
        // strong reference that causes a double-release crash on close().
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: true)
        window.onCancel = { [weak self] in self?.hide() }

        let root = LockScreenView(model: model, onDismiss: { [weak self] in self?.hide() })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = screen.frame
        window.contentView = hosting

        self.window = window

        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        model.stopPolling()
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    /// Debug: renders the window's own view hierarchy to a PNG. Works without
    /// screen-recording permission because it never touches the display server.
    func snapshot(to path: String) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("MuseSaver: snapshot failed — no window/view")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("MuseSaver: snapshot failed — PNG encode")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        NSLog("MuseSaver: snapshot written to \(path)")
    }
}
