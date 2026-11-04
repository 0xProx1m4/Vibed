import AppKit
import SwiftUI

/// Fenêtre plein écran, transparente aux clics, qui ne sert qu'à afficher une image.
private final class LockBackgroundPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true // les clics vont à macOS (mot de passe, avatar…)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canBecomeVisibleWithoutLogin = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Fond de l'écran verrouillé dessiné par Tide (pochette en plein écran), pour qu'il change
/// instantanément avec le morceau : appliquer un fond d'écran prend une à deux secondes à macOS.
///
/// La fenêtre est placée dans un espace au niveau de l'écran de verrouillage,
/// au niveau 2002 : entre le cache plein écran de loginwindow (2001) et son interface
/// (2004, horloge et mot de passe). Le fond d'écran continue d'être appliqué
/// en dessous : si la fenêtre finit cachée derrière, on retombe simplement sur l'ancien
/// comportement. Les niveaux se règlent sans recompiler (voir `Prefs.lockBackground…`).
@MainActor
final class LockBackground {
    static let shared = LockBackground()

    private var panels: [LockBackgroundPanel] = []
    /// Espace SkyLight de chaque fenêtre, pour l'en retirer.
    private var spaces: [ObjectIdentifier: Int32] = [:]
    private var isLocked = false
    private var unlockTask: Task<Void, Never>?

    private var isEnabled: Bool {
        let d = UserDefaults.standard
        return d.bool(forKey: Prefs.wallpaperMode) && d.bool(forKey: Prefs.instantBackground)
            && SkyLight.isAvailable
    }

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
        removeAll() // réglages ou écrans peut-être changés depuis le dernier verrouillage
        guard isEnabled else { return }

        let d = UserDefaults.standard
        let spaceLevel = Int32(truncatingIfNeeded: d.integer(forKey: Prefs.lockBackgroundSpaceLevel))
        let windowLevel = d.integer(forKey: Prefs.lockBackgroundWindowLevel)

        for screen in NSScreen.screens {
            let panel = LockBackgroundPanel(frame: screen.frame)
            panel.level = NSWindow.Level(rawValue: windowLevel)
            let hosting = NSHostingView(rootView: LockBackgroundView(size: screen.frame.size))
            hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            if let space = SkyLight.delegate(panel, level: spaceLevel) {
                spaces[ObjectIdentifier(panel)] = space
            }
            panels.append(panel)
        }
        scheduleDiagnostic(spaceLevel: spaceLevel, windowLevel: windowLevel)
    }

    // MARK: - Diagnostic

    /// Fichier où Tide note, à chaque verrouillage, les fenêtres affichées de l'avant vers
    /// l'arrière, avec leur niveau : on y voit où macOS dessine son fond et son interface,
    /// et où se trouve la fenêtre de fond de Tide.
    static var diagnosticFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tide/lock-diagnostic.txt")
    }

    private func scheduleDiagnostic(spaceLevel: Int32, windowLevel: Int) {
        let ours = Set(panels.map(\.windowNumber))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.isLocked else { return }
            let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            var lines = [
                "Tide – verrouillage du \(Date())",
                "Fond Tide : espace \(spaceLevel), niveau de fenêtre \(windowLevel), fenêtres \(ours.sorted())",
                "Visibles (les fenêtres Tide sont \(self.panels.map(\.isVisible))) :",
                "",
                "  n°  | niveau      | app                    | alpha | cadre",
            ]
            for window in info {
                let number = window[kCGWindowNumber as String] as? Int ?? 0
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                let bounds = (window[kCGWindowBounds as String] as? [String: Any]).flatMap {
                    CGRect(dictionaryRepresentation: $0 as CFDictionary)
                } ?? .zero
                let mark = ours.contains(number) ? "  ← FOND TIDE" : ""
                func pad(_ s: String, _ n: Int) -> String {
                    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
                }
                lines.append("\(pad(String(number), 5)) | \(pad(String(layer), 11)) | \(pad(owner, 22)) | "
                             + "\(String(format: "%.2f", alpha))  | \(NSStringFromRect(bounds))\(mark)")
            }
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(to: Self.diagnosticFile, atomically: true, encoding: .utf8)
            NSLog("%@", text)
        }
    }

    private func screenUnlocked() {
        isLocked = false
        // Même petit délai que la barre, pour ne pas clignoter pendant le déverrouillage.
        unlockTask?.cancel()
        unlockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, !self.isLocked else { return }
            self.removeAll()
        }
    }

    private func removeAll() {
        for panel in panels {
            if let space = spaces[ObjectIdentifier(panel)] { SkyLight.undelegate(panel, from: space) }
            panel.orderOut(nil)
        }
        panels = []
        spaces = [:]
    }
}

/// Même rendu que l'image de fond d'écran (`WallpaperRenderer`), mais dessiné directement :
/// pochette en plein écran légèrement zoomée, vignette, fondu enchaîné à chaque morceau.
private struct LockBackgroundView: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @AppStorage(Prefs.backgroundBlur) private var blur = 0.0
    let size: CGSize

    var body: some View {
        ZStack {
            if let art = spotify.artwork {
                ZStack {
                    Image(nsImage: art)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(1.12)
                        .saturation(1.08)
                        .brightness(-0.02)
                        .blur(radius: size.height * 0.012 * blur, opaque: true)
                        .frame(width: size.width, height: size.height)
                        .clipped()

                    // Vignette pour faire ressortir l'horloge et le lecteur
                    RadialGradient(colors: [.black.opacity(0), .black.opacity(0.3)], center: .center,
                                   startRadius: size.height * 0.3,
                                   endRadius: max(size.width, size.height) * 0.75)
                    LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0)],
                                   startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3))
                }
                .id(ObjectIdentifier(art))
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.35), value: spotify.artwork.map(ObjectIdentifier.init))
        .allowsHitTesting(false)
    }
}
