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

    /// Place la carte sous la pochette du fond d'écran (mêmes réglages Taille/Position).
    private func layout(_ panel: LockBarPanel, on screen: NSScreen) {
        let defaults = UserDefaults.standard
        let height = screen.frame.height
        let s = min(max(height / 900, 0.7), 1.8)
        let coverSide = height * defaults.double(forKey: Prefs.coverSize)
        let coverBottom = height * defaults.double(forKey: Prefs.coverCenter) + coverSide / 2 // depuis le haut
        let cardWidth = max(coverSide * 0.8, 300 * s)

        let margin: CGFloat = 30 // place pour l'ombre
        let cardHeight = 118 * s
        let size = CGSize(width: cardWidth + margin * 2, height: cardHeight + margin * 2)
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - (coverBottom - 34 * s) - cardHeight - margin
        )

        let hosting = FirstClickHostingView(
            rootView: LockBarContent(width: cardWidth, s: s, margin: margin)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Contenu de la barre : la carte du lecteur, uniquement si un morceau est chargé.
private struct LockBarContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    let width: CGFloat
    let s: CGFloat
    let margin: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let track = spotify.track {
                PlayerCard(track: track, width: width, s: s)
                    .padding(.top, margin)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: spotify.track?.id)
    }
}
