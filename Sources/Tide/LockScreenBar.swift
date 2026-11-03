import AppKit
import SwiftUI

/// Panneau configuré comme celui de boring.notch pour pouvoir vivre au-dessus du verrouillage.
private final class LockBarPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canBecomeVisibleWithoutLogin = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Vue hébergée qui réagit dès le premier clic.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Barre Liquid Glass (titre, durée, ⏮ ⏯ ⏭) affichée sur le VRAI écran de verrouillage,
/// juste sous la pochette dessinée dans le fond d'écran.
@MainActor
final class LockScreenBar {
    static let shared = LockScreenBar()

    private var panel: LockBarPanel?
    private var isLocked = false
    private var isDelegated = false
    private var unlockTask: Task<Void, Never>?

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked() }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenUnlocked() }
        }
    }

    private func screenLocked() {
        isLocked = true
        unlockTask?.cancel()
        guard UserDefaults.standard.bool(forKey: Prefs.lockScreenBar),
              SkyLight.isAvailable,
              let screen = NSScreen.screens.first else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel, on: screen)
        panel.orderFrontRegardless()

        if !isDelegated {
            SkyLight.delegate(panel)
            isDelegated = true
        }
    }

    private func screenUnlocked() {
        isLocked = false
        // Petit délai pour éviter un clignotement pendant l'animation de déverrouillage.
        unlockTask?.cancel()
        unlockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, !self.isLocked, let panel = self.panel else { return }
            if self.isDelegated {
                SkyLight.undelegate(panel)
                self.isDelegated = false
            }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> LockBarPanel {
        LockBarPanel(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
    }

    /// Place la barre à cheval sur le bas de la carte pochette (mêmes réglages Taille/Position).
    private func layout(_ panel: LockBarPanel, on screen: NSScreen) {
        let defaults = UserDefaults.standard
        let frame = screen.frame
        let card = WallpaperRenderer.Layout(
            coverSize: defaults.double(forKey: Prefs.coverSize),
            coverCenter: defaults.double(forKey: Prefs.coverCenter)
        ).cardRect(screenWidth: frame.width, screenHeight: frame.height)

        // ~74 % de la largeur de la pochette, ratio ~0,55, sous la pochette
        // avec un petit espace : elle ne la recouvre jamais.
        let barWidth = max(card.width * 0.74, 220)
        let s = barWidth / 250
        let barHeight = barWidth * 0.55
        let barTop = card.maxY + frame.height * 0.016 // depuis le haut

        let margin: CGFloat = 30 // place pour l'ombre
        let size = CGSize(width: barWidth + margin * 2, height: barHeight + margin * 2)
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - barTop - barHeight - margin
        )

        let hosting = FirstClickHostingView(
            rootView: LockBarContent(width: barWidth, height: barHeight, s: s, margin: margin)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Contenu de la barre, uniquement si un morceau est chargé.
private struct LockBarContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    let width: CGFloat
    let height: CGFloat
    let s: CGFloat
    let margin: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let track = spotify.track {
                CompactPlayer(track: track, s: s)
                    .frame(width: width, height: height)
                    .liquidGlass(cornerRadius: height * 0.13, darkness: 0.28)
                    .padding(.top, margin)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: spotify.track?.id)
    }
}

/// Lecteur compact : titre/artiste, progression avec temps, puis ⏮ ⏯ ⏭.
private struct CompactPlayer: View {
    @ObservedObject private var spotify = SpotifyController.shared
    let track: Track
    let s: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Titre + artiste, centrés ; petite onde à droite
            ZStack {
                VStack(spacing: 1 * s) {
                    Text(track.title)
                        .font(.system(size: 11 * s, weight: .semibold))
                    Text(track.artist)
                        .font(.system(size: 10 * s, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .padding(.horizontal, 16 * s)

                HStack {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 8.5 * s, weight: .bold))
                        .foregroundStyle(.white.opacity(spotify.isPlaying ? 0.75 : 0.3))
                }
            }

            Spacer(minLength: 0).frame(maxHeight: 8 * s)

            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                progress(current: spotify.scrubPosition ?? spotify.position(at: ctx.date))
            }

            Spacer(minLength: 0)

            HStack(spacing: 26 * s) {
                button("backward.fill", size: 14 * s) { spotify.previous() }
                button(spotify.isPlaying ? "pause.fill" : "play.fill", size: 19 * s) { spotify.playPause() }
                button("forward.fill", size: 14 * s) { spotify.next() }
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14 * s)
        .padding(.vertical, 8 * s)
    }

    private func button(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 1.9, height: size * 1.6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func progress(current: TimeInterval) -> some View {
        let duration = max(track.duration, 0.001)
        let fraction = min(max(current / duration, 0), 1)
        let scrubbing = spotify.scrubPosition != nil

        return HStack(spacing: 7 * s) {
            Text(PlayerCard.format(current))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white.opacity(0.9)).frame(width: g.size.width * fraction)
                }
                .frame(height: (scrubbing ? 6 : 3.5) * s)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            spotify.scrubPosition = min(max(value.location.x / g.size.width, 0), 1) * duration
                        }
                        .onEnded { value in
                            spotify.seek(to: min(max(value.location.x / g.size.width, 0), 1) * duration)
                            spotify.scrubPosition = nil
                        }
                )
                .animation(.spring(response: 0.25), value: scrubbing)
            }
            .frame(height: 12 * s)
            Text("-" + PlayerCard.format(track.duration - current))
        }
        .font(.system(size: 8.5 * s, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
    }
}
