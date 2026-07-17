import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let auth: SpotifyAuth
    private let windowController: LockScreenWindowController
    private let led: LEDController

    init(auth: SpotifyAuth, windowController: LockScreenWindowController, led: LEDController) {
        self.auth = auth
        self.windowController = windowController
        self.led = led
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        led.onStateChange = { [weak self] in self?.rebuildMenu() }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "moon.stars.fill",
                                   accessibilityDescription: "MuseSaver")
        }
        rebuildMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(spotifyStateChanged),
            name: .spotifyConnectionChanged,
            object: nil
        )
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if auth.isConnected {
            let status = NSMenuItem(title: "Spotify Connected", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else {
            let connect = NSMenuItem(title: "Connect Spotify…",
                                     action: #selector(connectSpotify),
                                     keyEquivalent: "")
            connect.target = self
            menu.addItem(connect)
        }

        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Lock Screen  (⌥⌘L)",
                              action: #selector(showLockScreen),
                              keyEquivalent: "l")
        show.target = self
        menu.addItem(show)

        let unlockToggle = NSMenuItem(title: "Show When Mac Unlocks",
                                      action: #selector(toggleShowOnUnlock),
                                      keyEquivalent: "")
        unlockToggle.target = self
        unlockToggle.state = Preferences.showOnUnlock ? .on : .off
        menu.addItem(unlockToggle)

        let ledTitle: String
        if !Preferences.syncLEDs {
            ledTitle = "Sync LEDs to Album Color"
        } else if led.isConnected {
            ledTitle = "Sync LEDs to Album Color (connected)"
        } else {
            ledTitle = "Sync LEDs to Album Color (searching…)"
        }
        let ledToggle = NSMenuItem(title: ledTitle,
                                   action: #selector(toggleLEDSync),
                                   keyEquivalent: "")
        ledToggle.target = self
        ledToggle.state = Preferences.syncLEDs ? .on : .off
        menu.addItem(ledToggle)

        if auth.isConnected {
            let disconnect = NSMenuItem(title: "Disconnect Spotify",
                                        action: #selector(disconnectSpotify),
                                        keyEquivalent: "")
            disconnect.target = self
            menu.addItem(disconnect)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MuseSaver",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func connectSpotify() {
        auth.connect()
    }

    @objc private func disconnectSpotify() {
        auth.disconnect()
        rebuildMenu()
    }

    @objc private func showLockScreen() {
        windowController.show()
    }

    @objc private func toggleShowOnUnlock() {
        Preferences.showOnUnlock.toggle()
        rebuildMenu()
    }

    @objc private func toggleLEDSync() {
        Preferences.syncLEDs.toggle()
        Preferences.syncLEDs ? led.enable() : led.disable()
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func spotifyStateChanged() {
        rebuildMenu()
    }
}
