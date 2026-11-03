import SwiftUI

struct LockScreenView: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var lock = LockScreenManager.shared

    var body: some View {
        GeometryReader { geo in
            let s = min(max(geo.size.height / 900, 0.7), 1.8)
            let side = geo.size.height * 0.40

            ZStack {
                AlbumBackground(image: spotify.artwork)
                    .contentShape(Rectangle())
                    .onTapGesture { lock.requestUnlock() }

                VStack(spacing: 0) {
                    ClockView(s: s)
                        .padding(.top, geo.size.height * 0.07)

                    Spacer(minLength: 24 * s)

                    Group {
                        if let track = spotify.track {
                            NowPlayingStack(track: track, artwork: spotify.artwork, side: side, s: s)
                        } else {
                            IdleCard(s: s)
                        }
                    }
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: spotify.track?.id)

                    Spacer(minLength: 24 * s)

                    UnlockHint(isAuthenticating: lock.isAuthenticating, s: s)
                        .padding(.bottom, 36 * s)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Fond

/// Pochette agrandie plein écran, légèrement floutée, qui dérive lentement.
struct AlbumBackground: View {
    let image: NSImage?
    private static let driftPeriod: TimeInterval = 20

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.driftPeriod)) { ctx in
            let drift = Int(ctx.date.timeIntervalSinceReferenceDate / Self.driftPeriod) % 2 == 1
            content(drift: drift)
                .animation(.easeInOut(duration: Self.driftPeriod), value: drift)
        }
    }

    private func content(drift: Bool) -> some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(drift ? 1.16 : 1.06)
                        .blur(radius: 22, opaque: true)
                        .clipped()
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                } else {
                    LinearGradient(
                        colors: [Color(red: 0.05, green: 0.12, blue: 0.30),
                                 Color(red: 0.02, green: 0.05, blue: 0.14)],
                        startPoint: .top, endPoint: .bottom
                    )
                }

                // Assombrissement haut/bas pour la lisibilité + vignette
                LinearGradient(
                    colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
                RadialGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    center: .center,
                    startRadius: geo.size.height * 0.35,
                    endRadius: geo.size.width * 0.75
                )
            }
            .animation(.easeInOut(duration: 1.2), value: image.map { ObjectIdentifier($0) })
        }
    }
}

// MARK: - Horloge

struct ClockView: View {
    let s: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 2 * s) {
                Text(ctx.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.system(size: 22 * s, weight: .semibold, design: .serif))
                    .foregroundStyle(.white.opacity(0.92))

                Text(ctx.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: 132 * s, weight: .bold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.97), Color(white: 0.82).opacity(0.85)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: .white.opacity(0.25), radius: 1, y: -1)   // reflet « verre »
                    .shadow(color: .black.opacity(0.35), radius: 18 * s, y: 6 * s)
            }
        }
    }
}

// MARK: - Lecture en cours

struct NowPlayingStack: View {
    let track: Track
    let artwork: NSImage?
    let side: CGFloat
    let s: CGFloat

    var body: some View {
        VStack(spacing: -34 * s) {
            ArtworkCard(image: artwork, side: side, s: s)
            PlayerCard(track: track, width: side * 0.80, s: s)
                .zIndex(1)
        }
        .transition(.scale(scale: 0.94).combined(with: .opacity))
    }
}

struct ArtworkCard: View {
    let image: NSImage?
    let side: CGFloat
    let s: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20 * s, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.22, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(0.45), radius: 40 * s, y: 24 * s)
        .animation(.easeInOut(duration: 0.6), value: image.map { ObjectIdentifier($0) })
    }
}

struct PlayerCard: View {
    @ObservedObject private var spotify = SpotifyController.shared
    let track: Track
    let width: CGFloat
    let s: CGFloat
    private var scrub: TimeInterval? { spotify.scrubPosition }

    var body: some View {
        VStack(spacing: 10 * s) {
            // Titre + artiste
            HStack(alignment: .center) {
                Image(systemName: "heart").opacity(0) // équilibre visuel
                    .font(.system(size: 11 * s))
                VStack(spacing: 2 * s) {
                    Text(track.title)
                        .font(.system(size: 14 * s, weight: .semibold))
                    Text(track.artist)
                        .font(.system(size: 12 * s, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                EqualizerIcon(isPlaying: spotify.isPlaying, height: 11 * s)
            }

            // Progression
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                progressRow(current: scrub ?? spotify.position(at: ctx.date))
            }

            // Contrôles
            HStack(spacing: 28 * s) {
                ControlButton(systemName: "backward.fill", size: 17 * s) { spotify.previous() }
                ControlButton(systemName: spotify.isPlaying ? "pause.fill" : "play.fill", size: 24 * s) {
                    spotify.playPause()
                }
                ControlButton(systemName: "forward.fill", size: 17 * s) { spotify.next() }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20 * s)
        .padding(.top, 14 * s)
        .padding(.bottom, 8 * s)
        .frame(width: width)
        .liquidGlass(cornerRadius: 24 * s)
    }

    private func progressRow(current: TimeInterval) -> some View {
        let duration = max(track.duration, 0.001)
        let fraction = min(max(current / duration, 0), 1)

        return HStack(spacing: 10 * s) {
            Text(Self.format(current))
                .frame(minWidth: 30 * s, alignment: .leading)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.92))
                        .frame(width: g.size.width * fraction)
                }
                .frame(height: (scrub == nil ? 5 : 8) * s)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            spotify.scrubPosition = min(max(value.location.x / g.size.width, 0), 1) * duration
                        }
                        .onEnded { value in
                            let target = min(max(value.location.x / g.size.width, 0), 1) * duration
                            spotify.seek(to: target)
                            spotify.scrubPosition = nil
                        }
                )
                .animation(.spring(response: 0.25), value: scrub == nil)
            }
            .frame(height: 16 * s)

            Text("-" + Self.format(track.duration - current))
                .frame(minWidth: 34 * s, alignment: .trailing)
        }
        .font(.system(size: 10 * s, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.75))
    }

    static func format(_ t: TimeInterval) -> String {
        let total = max(Int(t.rounded(.down)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 2, height: size * 2)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(highlight: .circle))
    }
}

// MARK: - Divers

struct IdleCard: View {
    let s: CGFloat

    var body: some View {
        VStack(spacing: 8 * s) {
            Image(systemName: "music.note")
                .font(.system(size: 28 * s, weight: .light))
            Text("Rien en lecture")
                .font(.system(size: 15 * s, weight: .semibold))
            Text("Lance un morceau dans Spotify")
                .font(.system(size: 12 * s))
                .foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 36 * s)
        .padding(.vertical, 24 * s)
        .liquidGlass(cornerRadius: 24 * s)
    }
}

struct UnlockHint: View {
    let isAuthenticating: Bool
    let s: CGFloat

    var body: some View {
        HStack(spacing: 8 * s) {
            Image(systemName: isAuthenticating ? "touchid" : "lock.fill")
            Text(isAuthenticating ? "Authentification…" : "Touch ID ou mot de passe pour déverrouiller")
        }
        .font(.system(size: 12 * s, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16 * s)
        .padding(.vertical, 8 * s)
        .liquidGlass(Capsule())
    }
}
