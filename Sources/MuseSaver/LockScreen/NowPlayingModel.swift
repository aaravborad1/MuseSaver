import AppKit
import Combine
import CoreImage
import SwiftUI

/// Central observable store for the lock screen. Polls Spotify while the window is
/// open, loads lyrics and artwork on track changes, and estimates playback position
/// between polls so lyric highlighting stays smooth.
@MainActor
final class NowPlayingModel: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkColor: Color?

    /// Raw NSColor of the artwork tint; forwarded to onTintChange (LED sync).
    private(set) var artworkNSColor: NSColor? {
        didSet {
            artworkColor = artworkNSColor.map { Color(nsColor: $0) }
            if let color = artworkNSColor { onTintChange?(color) }
        }
    }
    var onTintChange: ((NSColor) -> Void)?
    @Published private(set) var lyrics: [LyricLine] = []
    @Published private(set) var isConnected: Bool
    @Published private(set) var shuffleOn = false
    @Published private(set) var repeatMode = "off"

    private let auth: SpotifyAuth
    private let api: SpotifyAPI
    private let lyricsService = LyricsService()

    private var pollTask: Task<Void, Never>?
    private var currentTrackKey: String?
    private var progressMs: Double = 0
    private var progressAnchor = Date()

    /// Artwork + derived color cached per track so revisits render instantly.
    private var artworkCache: [String: (image: NSImage, color: NSColor?)] = [:]

    init(auth: SpotifyAuth) {
        self.auth = auth
        self.api = SpotifyAPI(auth: auth)
        self.isConnected = auth.isConnected
    }

    var hasLyrics: Bool { !lyrics.isEmpty }

    // MARK: - Polling lifecycle

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                // Poll faster near the end of a track (and right after a change)
                // so the next song appears promptly instead of lagging ~2.5s.
                let interval: UInt64 = (self?.isNearTrackBoundary() ?? false)
                    ? 800_000_000
                    : 2_500_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// True in the last few seconds of a track, when a change is imminent.
    private func isNearTrackBoundary() -> Bool {
        guard let track, isPlaying else { return false }
        let remaining = Double(track.durationMs) / 1000 - estimatedProgress()
        return remaining < 6
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        isConnected = auth.isConnected
        guard auth.isConnected else { return }
        do {
            let playing = try await api.currentlyPlaying()
            guard let playing, let track = playing.item else {
                isPlaying = false
                return
            }
            // Always keep playback state fresh, even for tracks with no id
            // (e.g. local files), so the UI reflects what's playing.
            isPlaying = playing.isPlaying
            progressMs = Double(playing.progressMs ?? 0)
            progressAnchor = Date()
            self.track = track
            shuffleOn = playing.shuffleState ?? false
            repeatMode = playing.repeatState ?? "off"

            let key = track.id ?? "\(track.name)::\(track.artistNames)"
            if key != currentTrackKey {
                currentTrackKey = key
                // Lyrics belong to the old song — clear immediately. But keep the
                // old artwork/color on screen until the new ones arrive, so the
                // transition is a crossfade instead of a flash to black.
                lyrics = []
                if let cached = artworkCache[key] {
                    artwork = cached.image
                    artworkNSColor = cached.color
                }
                await loadDetails(for: track, key: key)
                // Warm the caches for what's coming next so the transition to the
                // next song (artwork, color, lyrics) is instant.
                Task { [weak self] in await self?.prefetchUpcoming() }
            }
        } catch {
            // Errors are non-fatal (the next poll retries), but log them so
            // failures are visible in Console instead of silently blank UI.
            NSLog("MuseSaver: poll failed — \(error)")
        }
    }

    private func loadDetails(for track: Track, key: String) async {
        async let lyricLines = lyricsService.lyrics(for: track)

        // Artwork: serve from cache; otherwise fetch and cache alongside its color.
        if artworkCache[key] == nil, let loaded = await Self.loadImage(from: track.albumArtURL) {
            artworkCache[key] = (loaded, Self.backgroundColor(from: loaded))
            // Cap memory: drop oldest entries past 30 tracks.
            if artworkCache.count > 30, let drop = artworkCache.keys.first(where: { $0 != key }) {
                artworkCache.removeValue(forKey: drop)
            }
        }

        // Show the artwork as soon as it's available — don't wait on lyrics.
        if key == currentTrackKey, let cached = artworkCache[key] {
            artwork = cached.image
            artworkNSColor = cached.color
        }

        let loadedLyrics = await lyricLines
        // Discard results if the track changed while loading.
        guard key == currentTrackKey else { return }
        lyrics = loadedLyrics
        NSLog("MuseSaver: loaded '\(track.name)' — image=\(artworkCache[key] != nil) lyrics=\(loadedLyrics.count)")
    }

    private static func loadImage(from url: URL?) async -> NSImage? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    /// Derives a rich, legible background tone from the artwork's average color,
    /// boosting saturation and clamping brightness so it never reads as muddy black.
    private static func backgroundColor(from image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let ciImage = CIImage(data: tiff) else { return nil }

        let extent = ciImage.extent
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])
        guard let output = filter?.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output,
                       toBitmap: &pixel,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        let base = NSColor(red: CGFloat(pixel[0]) / 255,
                           green: CGFloat(pixel[1]) / 255,
                           blue: CGFloat(pixel[2]) / 255,
                           alpha: 1)
        guard let hsb = base.usingColorSpace(.deviceRGB) else { return base }

        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        hsb.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let boosted = NSColor(hue: hue,
                              saturation: min(sat * 1.4, 1.0),
                              brightness: max(min(bri * 1.15, 0.72), 0.4),
                              alpha: 1)
        return boosted
    }

    /// Prefetches lyrics + artwork (+ derived color) for the next couple of queue
    /// tracks. The lyrics service caches internally; artwork goes into our cache.
    private func prefetchUpcoming() async {
        guard let upcoming = try? await api.upcomingQueue() else { return }
        for track in upcoming.prefix(2) {
            let key = track.id ?? "\(track.name)::\(track.artistNames)"
            _ = await lyricsService.lyrics(for: track)
            if artworkCache[key] == nil,
               let image = await Self.loadImage(from: track.albumArtURL) {
                artworkCache[key] = (image, Self.backgroundColor(from: image))
            }
        }
    }

    // MARK: - Debug

    /// Loads a synthetic track (with real artwork + lyrics fetches) so the full
    /// lock screen UI can be exercised without a Spotify connection.
    func debugLoadSynthetic() async {
        let synthetic = Track(
            id: "debug",
            name: "Blinding Lights",
            durationMs: 200_040,
            artists: [Artist(name: "The Weeknd")],
            album: Album(name: "After Hours",
                         images: [SpotifyImage(url: "https://i.scdn.co/image/ab67616d0000b2738863bc11d2aa12b54f5aeb36",
                                               width: 640, height: 640)])
        )
        track = synthetic
        isPlaying = true
        progressMs = 45_000
        progressAnchor = Date()
        currentTrackKey = "debug"
        await loadDetails(for: synthetic, key: "debug")
    }

    // MARK: - Playback commands

    /// Runs a player command with an optimistic UI update, then re-polls shortly
    /// after so the real state (from Spotify) corrects any drift.
    private func perform(_ action: @escaping () async throws -> Void,
                         optimistic: () -> Void) {
        optimistic()
        Task { [weak self] in
            do {
                try await action()
            } catch {
                NSLog("MuseSaver: player command failed — \(error)")
            }
            // Spotify's API is eventually consistent; give it a moment.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await self?.poll()
        }
    }

    func togglePlayPause() {
        let wasPlaying = isPlaying
        // Freeze the extrapolated position now so pause/resume feels instant.
        let currentMs = estimatedProgress() * 1000
        perform({ [api] in wasPlaying ? try await api.pause() : try await api.play() },
                optimistic: {
                    progressMs = currentMs
                    progressAnchor = Date()
                    isPlaying = !wasPlaying
                })
    }

    func nextTrack() {
        perform({ [api] in try await api.nextTrack() }, optimistic: {})
    }

    func previousTrack() {
        perform({ [api] in try await api.previousTrack() }, optimistic: {})
    }

    func toggleShuffle() {
        let target = !shuffleOn
        perform({ [api] in try await api.setShuffle(target) },
                optimistic: { shuffleOn = target })
    }

    func cycleRepeat() {
        let next: String
        switch repeatMode {
        case "off": next = "context"
        case "context": next = "track"
        default: next = "off"
        }
        perform({ [api] in try await api.setRepeat(next) },
                optimistic: { repeatMode = next })
    }

    /// Seeks to a fraction (0...1) of the current track.
    func seek(toFraction fraction: Double) {
        guard let track else { return }
        let clamped = min(max(fraction, 0), 1)
        let targetMs = Int(clamped * Double(track.durationMs))
        perform({ [api] in try await api.seek(toMs: targetMs) },
                optimistic: {
                    progressMs = Double(targetMs)
                    progressAnchor = Date()
                })
    }

    // MARK: - Playback position

    /// Estimated playback position in seconds, extrapolated from the last poll.
    func estimatedProgress() -> TimeInterval {
        var ms = progressMs
        if isPlaying {
            ms += Date().timeIntervalSince(progressAnchor) * 1000
        }
        return ms / 1000
    }

    /// Fraction of the track elapsed (0...1) for the progress bar.
    func progressFraction() -> Double {
        guard let track, track.durationMs > 0 else { return 0 }
        let fraction = estimatedProgress() / (Double(track.durationMs) / 1000)
        return min(max(fraction, 0), 1)
    }

    /// Index of the lyric line that should currently be highlighted.
    func currentLyricIndex() -> Int? {
        guard !lyrics.isEmpty else { return nil }
        let now = estimatedProgress()
        var index: Int?
        for (i, line) in lyrics.enumerated() {
            if line.time <= now {
                index = i
            } else {
                break
            }
        }
        return index
    }
}
