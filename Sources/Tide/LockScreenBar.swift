import AppKit
import SwiftUI

/// Panneau transparent qui ne vole pas le focus.
private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Vue hébergée qui réagit dès le premier clic (pas besoin d'activer l'app d'abord).
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Barre Liquid Glass (titre, durée, ⏮ ⏯ ⏭) affichée sur le VRAI écran de verrouillage,
/// juste sous la pochette dessinée dans le fond d'écran.
@MainActor
final class LockScreenBar {
    static let shared = LockScreenBar()

    private var window: NSPanel?
    private var isLocked = false

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isLocked = true
                self?.show()
            }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.isLocked = false
                self?.hide()
            }
        }
    }

    private func show() {
        guard isLocked,
              UserDefaults.standard.bool(forKey: Prefs.lockScreenBar),
              SkyLight.isAvailable,
              let screen = NSScreen.screens.first else { return }
        hide()

        let defaults = UserDefaults.standard
        let height = screen.frame.height
        let s = min(max(height / 900, 0.7), 1.8)
        let coverSide = height * defaults.double(forKey: Prefs.coverSize)
        let coverBottom = height * defaults.double(forKey: Prefs.coverCenter) + coverSide / 2 // depuis le haut
        let cardWidth = max(coverSide * 0.8, 300 * s)

        let hosting = FirstClickHostingView(
            rootView: LockBarContent(width: cardWidth, s: s)
                .environment(\.colorScheme, .dark)
        )
        // Marge autour de la carte pour son ombre
        let margin: CGFloat = 30
        let cardHeight = 118 * s
        let size = CGSize(width: cardWidth + margin * 2, height: cardHeight + margin * 2)
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - (coverBottom - 34 * s) - cardHeight - margin
        )

        let panel = BarPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.orderFrontRegardless()

        SkyLight.moveAboveLockScreen(panel)
        window = panel
    }

    private func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

/// Contenu de la barre : la carte du lecteur, centrée, uniquement si un morceau est chargé.
private struct LockBarContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    let width: CGFloat
    let s: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let track = spotify.track {
                PlayerCard(track: track, width: width, s: s)
                    .padding(.top, 30)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: spotify.track?.id)
    }
}
