import SwiftUI

/// The fullscreen lock screen UI: a background tinted from the album art, a clock,
/// the artwork, a frosted mini-player, and time-synced lyrics.
struct LockScreenView: View {
    @ObservedObject var model: NowPlayingModel
    var onDismiss: () -> Void

    /// Tapping the artwork declutters the screen (iOS-style): everything except the
    /// artwork and clock fades out. Reset each time the window opens.
    /// (MUSESAVER_DEBUG_DECLUTTER=1 starts decluttered, for snapshot testing.)
    @State private var showDetails =
        ProcessInfo.processInfo.environment["MUSESAVER_DEBUG_DECLUTTER"] != "1"

    var body: some View {
        ZStack {
            background
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            content
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    private var background: some View {
        // GeometryReader pins every layer to the screen size. Without the explicit
        // frame + clip, the scaledToFill artwork inflates the ZStack beyond the
        // window and shifts all foreground content off-screen.
        GeometryReader { geo in
            ZStack {
                // Base tone derived from the artwork (falls back to a neutral dark).
                let tint = model.artworkColor ?? Color(white: 0.12)
                LinearGradient(
                    colors: [
                        tint.opacity(0.98),
                        tint.opacity(0.80),
                        Color.black.opacity(0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Heavily blurred artwork over the tint adds depth, like the real thing.
                if let artwork = model.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 120)
                        .opacity(0.45)
                        .overlay(Color.black.opacity(0.15))
                }

                // Gentle vignette so the clock and text stay readable.
                LinearGradient(
                    colors: [.black.opacity(0.35), .clear, .black.opacity(0.45)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .animation(.easeInOut(duration: 0.7), value: model.artworkColor)
        .animation(.easeInOut(duration: 0.7), value: model.artwork)
    }

    // MARK: - Foreground content

    private var content: some View {
        VStack(spacing: 0) {
            // The clock owns a fixed slot at the top so content can never push it
            // off screen. Decluttered (details hidden): full size. With lyrics and
            // player showing: scaled down to make room.
            // Top clock (details mode). In decluttered mode it fades out and the
            // big album-height clock beside the artwork takes over. The slot keeps
            // its size in both modes so nothing jumps during the crossfade.
            // fixedSize defeats TimelineView's greedy sizing.
            clockView(dateSize: 24, timeSize: 94)
                .fixedSize()
                .frame(height: 152, alignment: .top)
                .padding(.top, 72)
                .opacity(showDetails ? 1 : 0)

            Spacer(minLength: 16)

            if model.track != nil {
                HStack(alignment: .center, spacing: 64) {
                    trackColumn
                        .frame(width: 340)

                    if model.hasLyrics {
                        LyricsView(model: model)
                            .frame(maxWidth: 560)
                            .opacity(showDetails ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 90)
            } else {
                Text("Nothing playing")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Clock

    /// Dynamic-glass clock, reusable at any size. `fillHeight` pushes the date to
    /// the top and the time to the bottom of the available frame (used beside the
    /// album art so both edges align with the artwork).
    private func clockView(dateSize: CGFloat,
                           timeSize: CGFloat,
                           alignment: HorizontalAlignment = .center,
                           fillHeight: Bool = false) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let date = context.date
            let tint = model.artworkColor ?? Color.white

            VStack(alignment: alignment, spacing: dateSize * 0.25) {
                Text(date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: dateSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)

                if fillHeight { Spacer(minLength: 0) }

                // Layered "dynamic glass" numerals:
                //  1. translucent glyph body blending white with the album color
                //  2. a bright top highlight, like light catching the glass edge
                //  3. slight overall translucency + a colored glow to sit the
                //     clock *in* the artwork rather than on top of it
                ZStack {
                    timeText(date, size: timeSize)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.98),
                                    tint.opacity(0.85),
                                    .white.opacity(0.55)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    timeText(date, size: timeSize)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white.opacity(0.85), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .blendMode(.screen)
                }
                .compositingGroup()
                .opacity(0.92)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
                .shadow(color: tint.opacity(0.55), radius: 46)
            }
            .animation(.easeInOut(duration: 0.7), value: model.artworkColor)
        }
        .allowsHitTesting(false)
    }

    private func timeText(_ date: Date, size: CGFloat) -> some View {
        Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .kerning(1)
    }

    // MARK: - Track column (artwork + frosted mini-player)

    private var trackColumn: some View {
        VStack(spacing: 22) {
            artwork
            miniPlayer
                .opacity(showDetails ? 1 : 0)
                .allowsHitTesting(showDetails)
        }
    }

    private var artwork: some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.4))
                    )
            }
        }
        .frame(width: 300, height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 34, y: 18)
        .animation(.easeInOut(duration: 0.45), value: model.artwork)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showDetails.toggle()
            }
        }
        // Decluttered mode: a big clock beside the artwork, spanning exactly the
        // artwork's height (date at the art's top edge, time at its bottom edge).
        .overlay(alignment: .topLeading) {
            clockView(dateSize: 30, timeSize: 170, alignment: .leading, fillHeight: true)
                .frame(height: 300)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: 300 + 56)
                .opacity(showDetails ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    /// Frosted glass "mini player" pill, echoing the iOS/macOS now-playing widget.
    private var miniPlayer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                artworkThumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.track?.name ?? "")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(model.track?.artistNames ?? "")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            progressBar

            HStack(spacing: 30) {
                controlButton("shuffle", size: 15,
                              opacity: model.shuffleOn ? 1 : 0.45) {
                    model.toggleShuffle()
                }
                controlButton("backward.fill", size: 20, opacity: 0.9) {
                    model.previousTrack()
                }
                controlButton(model.isPlaying ? "pause.fill" : "play.fill",
                              size: 24, opacity: 1) {
                    model.togglePlayPause()
                }
                controlButton("forward.fill", size: 20, opacity: 0.9) {
                    model.nextTrack()
                }
                controlButton(model.repeatMode == "track" ? "repeat.1" : "repeat",
                              size: 15,
                              opacity: model.repeatMode == "off" ? 0.45 : 1) {
                    model.cycleRepeat()
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var artworkThumbnail: some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func controlButton(_ symbol: String, size: CGFloat, opacity: Double,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.white.opacity(opacity))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: 5)
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: geo.size.width * model.progressFraction(), height: 5)
                }
                // The visible bar is 5pt tall, but the hit area spans the full
                // 18pt row so it's easy to click/scrub.
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            model.seek(toFraction: value.location.x / geo.size.width)
                        }
                )
            }
        }
        .frame(height: 18)
    }
}

// MARK: - Lyrics

private struct LyricsView: View {
    @ObservedObject var model: NowPlayingModel
    @State private var currentIndex: Int?

    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(model.lyrics.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 30, weight: index == currentIndex ? .bold : .semibold))
                            .foregroundStyle(color(for: index))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.vertical, 200)
                .animation(.easeInOut(duration: 0.25), value: currentIndex)
            }
            .frame(height: 470)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.2),
                        .init(color: .black, location: 0.8),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onReceive(ticker) { _ in
                let index = model.currentLyricIndex()
                guard index != currentIndex else { return }
                currentIndex = index
                if let index {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private func color(for index: Int) -> Color {
        guard let current = currentIndex else { return .white.opacity(0.5) }
        if index == current { return .white }
        if index < current { return .white.opacity(0.3) }
        return .white.opacity(0.55)
    }
}
