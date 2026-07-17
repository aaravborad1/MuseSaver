import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var auth: SpotifyAuth!
    private var model: NowPlayingModel!
    private var windowController: LockScreenWindowController!
    private var menuBar: MenuBarController!
    private var hotKey: HotKeyManager!
    private var unlockObserver: UnlockObserver!
    private var led: LEDController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let auth = SpotifyAuth()
        let model = NowPlayingModel(auth: auth)
        let windowController = LockScreenWindowController(model: model)
        let led = LEDController()

        self.auth = auth
        self.model = model
        self.windowController = windowController
        self.led = led
        self.menuBar = MenuBarController(auth: auth, windowController: windowController, led: led)

        // LED sync: push each song's extracted album color to the strip.
        model.onTintChange = { [weak led] color in
            led?.setColor(color)
        }
        if Preferences.syncLEDs {
            led.enable()
        }

        // Debug: MUSESAVER_DEBUG_LED=1 forces LED scanning on (with discovery
        // logging); optionally MUSESAVER_DEBUG_LED_COLOR=ff2200 sends a test
        // color 8s after launch so the strip visibly reacts.
        if ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_LED"] == "1" {
            led.enable()
            if let hex = ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_LED_COLOR"],
               let value = UInt32(hex, radix: 16) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak led] in
                    led?.setColor(NSColor(red: CGFloat((value >> 16) & 0xFF) / 255,
                                          green: CGFloat((value >> 8) & 0xFF) / 255,
                                          blue: CGFloat(value & 0xFF) / 255,
                                          alpha: 1))
                }
            }
        }

        // Global hotkey ⌥⌘L toggles the lock screen from anywhere.
        let hotKey = HotKeyManager()
        hotKey.onHotKey = { [weak windowController] in
            windowController?.toggle()
        }
        hotKey.register()
        self.hotKey = hotKey

        // Show automatically when the Mac is unlocked (optional, on by default).
        let unlockObserver = UnlockObserver()
        unlockObserver.onUnlock = { [weak windowController] in
            guard Preferences.showOnUnlock else { return }
            windowController?.show()
        }
        self.unlockObserver = unlockObserver

        // Headless diagnostic: MUSESAVER_DEBUG_POLL=1 runs one full data-pipeline
        // pass (keychain -> token -> currently-playing -> artwork -> lyrics),
        // prints results to stderr, and exits. Used for debugging from a terminal.
        if ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_POLL"] == "1" {
            Task { await Self.runDebugProbe(auth: auth) }
        }

        // Visual diagnostic: MUSESAVER_DEBUG_SHOW=1 opens the lock screen right
        // after launch so it can be screenshotted from a script.
        if ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.windowController.show()
            }
        }

        // Visual diagnostic: MUSESAVER_DEBUG_SNAPSHOT=/path.png opens the lock
        // screen, waits for content to load, writes a PNG of the window's own
        // view hierarchy (no screen-recording permission needed), and exits.
        if let snapshotPath = ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_SNAPSHOT"] {
            let fake = ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_FAKE"] == "1"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.windowController.show()
                if fake, let model = self?.model {
                    Task { await model.debugLoadSynthetic() }
                }
                let delay = Double(ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_SNAPSHOT_DELAY"] ?? "") ?? 5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self?.windowController.snapshot(to: snapshotPath)
                    exit(0)
                }
            }
        }
    }

    private static func runDebugProbe(auth: SpotifyAuth) async {
        FileHandle.standardError.write(Data("PROBE: start\n".utf8))
        func out(_ s: String) { FileHandle.standardError.write(Data("PROBE: \(s)\n".utf8)) }

        // Read the keychain directly (we're off the main thread here).
        let hasToken = await Task.detached { Keychain.get(account: "refresh-token") != nil }.value
        out("keychain refresh token present: \(hasToken)")

        guard hasToken else {
            // Not connected — still exercise the artwork + lyrics pipeline with a
            // well-known track so those paths are verifiable without auth.
            out("no token; running synthetic artwork/lyrics test")
            let synthetic = Track(
                id: "synthetic",
                name: "Blinding Lights",
                durationMs: 200_040,
                artists: [Artist(name: "The Weeknd")],
                album: Album(name: "After Hours",
                             images: [SpotifyImage(url: "https://i.scdn.co/image/ab67616d0000b2738863bc11d2aa12b54f5aeb36",
                                                   width: 640, height: 640)])
            )
            if let url = synthetic.albumArtURL {
                do {
                    let (data, resp) = try await URLSession.shared.data(from: url)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    out("artwork fetch: HTTP \(code), \(data.count) bytes, NSImage=\(NSImage(data: data) != nil)")
                } catch {
                    out("artwork fetch FAILED: \(error)")
                }
            }
            let lines = await LyricsService().lyrics(for: synthetic)
            out("lyrics: \(lines.count) synced lines")
            if let first = lines.first { out("first line @\(first.time)s: \(first.text)") }
            out("done (synthetic)")
            exit(0)
        }

        do {
            let token = try await auth.validAccessToken()
            out("access token OK (\(token.prefix(10))…)")
        } catch {
            out("access token FAILED: \(error)")
            exit(2)
        }

        let api = SpotifyAPI(auth: auth)
        do {
            guard let playing = try await api.currentlyPlaying() else {
                out("currently-playing: nothing playing (HTTP 204)")
                exit(0)
            }
            guard let track = playing.item else {
                out("currently-playing: no item (podcast or ad?)")
                exit(0)
            }
            out("track: '\(track.name)' by \(track.artistNames), playing=\(playing.isPlaying)")
            out("albumArtURL: \(track.albumArtURL?.absoluteString ?? "NIL")")

            if let url = track.albumArtURL {
                do {
                    let (data, resp) = try await URLSession.shared.data(from: url)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    out("artwork fetch: HTTP \(code), \(data.count) bytes, NSImage=\(NSImage(data: data) != nil)")
                } catch {
                    out("artwork fetch FAILED: \(error)")
                }
            }

            let lyrics = await LyricsService().lyrics(for: track)
            out("lyrics: \(lyrics.count) synced lines")
            if let first = lyrics.first { out("first line @\(first.time)s: \(first.text)") }
        } catch {
            out("currently-playing FAILED: \(error)")
            exit(3)
        }
        out("done")
        exit(0)
    }
}
