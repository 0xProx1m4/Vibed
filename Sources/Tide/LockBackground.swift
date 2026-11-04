import AppKit
import SwiftUI

/// Full-screen, click-through window whose only job is to show an image.
private final class LockBackgroundPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true // clicks go through to macOS (password, avatar…)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canBecomeVisibleWithoutLogin = true
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lock screen background drawn by Tide (full-screen artwork), so it changes
/// instantly with the track: applying a wallpaper takes macOS one to two seconds.
///
/// The window is placed in a space at the lock screen level,
/// at window level 2002: between loginwindow's full-screen cover (2001) and its UI
/// (2004, clock and password). The wallpaper keeps being applied
/// underneath: if the window ends up hidden behind, we simply fall back to the old
/// behavior. The levels can be tuned without recompiling (see `Prefs.lockBackground…`).
@MainActor
final class LockBackground {
    static let shared = LockBackground()

    private var panels: [LockBackgroundPanel] = []
    /// SkyLight space of each window, so it can be removed from it.
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
        removeAll() // settings or displays may have changed since the last lock
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

    /// File where Tide records, on every lock, the on-screen windows from front to
    /// back, with their level: it shows where macOS draws its background and UI,
    /// and where Tide's background window sits.
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
                "Tide – lock at \(Date())",
                "Tide background: space \(spaceLevel), window level \(windowLevel), windows \(ours.sorted())",
                "Visible (Tide windows are \(self.panels.map(\.isVisible))):",
                "",
                "  no. | level       | app                    | alpha | frame",
            ]
            for window in info {
                let number = window[kCGWindowNumber as String] as? Int ?? 0
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                let bounds = (window[kCGWindowBounds as String] as? [String: Any]).flatMap {
                    CGRect(dictionaryRepresentation: $0 as CFDictionary)
                } ?? .zero
                let mark = ours.contains(number) ? "  ← TIDE BACKGROUND" : ""
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
        // Same short delay as the bar, to avoid flickering during unlock.
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

/// Same look as the wallpaper image (`WallpaperRenderer`), but drawn directly.
/// Everything is designed so the change is as fast as the center artwork:
/// the image is shown as-is (no full-screen filter to recompute), only it
/// cross-fades, and the vignette stays fixed on top.
private struct LockBackgroundView: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @AppStorage(Prefs.backgroundBlur) private var blur = 0.0
    let size: CGSize

    var body: some View {
        ZStack {
            if let art = spotify.artwork {
                artwork(art)
                    .id(ObjectIdentifier(art))
                    .transition(.opacity)

                // Vignette to make the clock and player stand out (fixed, never redrawn)
                ZStack {
                    RadialGradient(colors: [.black.opacity(0), .black.opacity(0.3)], center: .center,
                                   startRadius: size.height * 0.3,
                                   endRadius: max(size.width, size.height) * 0.75)
                    LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0)],
                                   startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3))
                }
                .transition(.identity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: LockTiming.artworkFade), value: spotify.artwork.map(ObjectIdentifier.init))
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func artwork(_ art: NSImage) -> some View {
        let image = art.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map { Image(decorative: $0, scale: 1) } ?? Image(nsImage: art)
        let view = image
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .scaleEffect(1.12)
            .frame(width: size.width, height: size.height)
            .clipped()
        // Blur is expensive at full screen: only when it's enabled.
        if blur > 0 {
            view.blur(radius: size.height * 0.012 * blur, opaque: true)
        } else {
            view
        }
    }
}

/// Shared duration of artwork cross-fades on the lock screen (background and center
/// artwork stay in sync).
enum LockTiming {
    static let artworkFade: Double = 0.2
}
