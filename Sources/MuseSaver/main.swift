import AppKit

// MuseSaver runs as a menu bar (accessory) app: no Dock icon, no main window.
// Top-level executable code runs on the main thread, so it is safe to build the
// main-actor-isolated AppDelegate here.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
