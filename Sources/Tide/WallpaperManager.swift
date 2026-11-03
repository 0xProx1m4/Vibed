import AppKit
import Combine

/// Met la pochette du morceau en cours en fond d'écran du Mac.
/// Depuis macOS Sonoma, le vrai écran de verrouillage utilise ce fond d'écran :
/// macOS y dessine par-dessus son horloge et son lecteur « En lecture ».
@MainActor
final class WallpaperManager {
    static let shared = WallpaperManager()

    private var cancellables = Set<AnyCancellable>()
    private var restoreWork: DispatchWorkItem?
    private var generation = 0
    private var lastSettings: Settings?
    private let renderQueue = DispatchQueue(label: "app.tide.wallpaper", qos: .utility)
    private let folder: URL

    private static let originalsKey = "originalWallpapers"

    private struct Settings: Equatable {
        var enabled: Bool
        var restoreWhenIdle: Bool
        var coverSize: Double
        var coverCenter: Double

        static var current: Settings {
            let d = UserDefaults.standard
            return Settings(
                enabled: d.bool(forKey: Prefs.wallpaperMode),
                restoreWhenIdle: d.bool(forKey: Prefs.restoreWallpaperWhenIdle),
                coverSize: d.double(forKey: Prefs.coverSize),
                coverCenter: d.double(forKey: Prefs.coverCenter)
            )
        }
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Tide/Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: - Cycle de vie

    func start() {
        lastSettings = .current

        SpotifyController.shared.$artwork
            .removeDuplicates { $0 === $1 }
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] image in self?.artworkChanged(image) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// À appeler en quittant l'app : on remet le fond d'écran d'origine.
    func restoreOriginal() {
        restoreWork?.cancel()
        generation += 1 // annule un rendu en cours
        let saved = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        guard !saved.isEmpty else { return }

        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen), let path = saved[id] else { continue }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
        UserDefaults.standard.removeObject(forKey: Self.originalsKey)
        cleanUp(keeping: [])
    }

    // MARK: - Réactions

    private func artworkChanged(_ image: NSImage?) {
        let settings = Settings.current
        guard settings.enabled else { return }

        if let image {
            restoreWork?.cancel()
            apply(image, settings: settings)
        } else if settings.restoreWhenIdle {
            // Rien en lecture : on attend un peu (changement de morceau, pub…) avant de restaurer.
            restoreWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard SpotifyController.shared.artwork == nil else { return }
                    self?.restoreOriginal()
                }
            }
            restoreWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
        }
    }

    private func settingsChanged() {
        let settings = Settings.current
        guard settings != lastSettings else { return }
        lastSettings = settings

        if settings.enabled {
            refresh()
        } else {
            restoreOriginal()
        }
    }

    private func refresh() {
        let settings = Settings.current
        guard settings.enabled, let image = SpotifyController.shared.artwork else { return }
        apply(image, settings: settings)
    }

    // MARK: - Rendu

    private func apply(_ image: NSImage, settings: Settings) {
        guard let cover = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        saveOriginalsIfNeeded()

        generation += 1
        let gen = generation
        let layout = WallpaperRenderer.Layout(coverSize: settings.coverSize, coverCenter: settings.coverCenter)
        let targets: [(id: String, size: CGSize)] = NSScreen.screens.compactMap { screen in
            guard let id = Self.displayID(of: screen) else { return nil }
            let scale = screen.backingScaleFactor
            return (id, CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale))
        }
        let folder = self.folder

        renderQueue.async { [weak self] in
            var files: [String: URL] = [:]
            for target in targets {
                guard let data = WallpaperRenderer.render(cover: cover, pixelSize: target.size, layout: layout) else { continue }
                // Nom unique : macOS ne recharge pas un fond d'écran dont le chemin n'a pas changé.
                let url = folder.appendingPathComponent("tide-\(target.id)-\(UUID().uuidString.prefix(8)).jpg")
                if (try? data.write(to: url, options: .atomic)) != nil { files[target.id] = url }
            }

            Task { @MainActor in
                guard let self, gen == self.generation else {
                    files.values.forEach { try? FileManager.default.removeItem(at: $0) }
                    return
                }
                for screen in NSScreen.screens {
                    guard let id = Self.displayID(of: screen), let url = files[id] else { continue }
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                            .allowClipping: true,
                        ])
                    } catch {
                        NSLog("Tide – impossible de changer le fond d'écran : %@", error.localizedDescription)
                    }
                }
                self.cleanUp(keeping: Set(files.values))
            }
        }
    }

    /// Mémorise le fond d'écran de l'utilisateur (une seule fois, tant qu'il n'a pas été restauré).
    private func saveOriginalsIfNeeded() {
        var saved = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        var changed = false
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen), saved[id] == nil,
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !url.path.hasPrefix(folder.path) else { continue }
            saved[id] = url.path
            changed = true
        }
        if changed { UserDefaults.standard.set(saved, forKey: Self.originalsKey) }
    }

    private func cleanUp(keeping keep: Set<URL>) {
        let keepPaths = Set(keep.map(\.standardizedFileURL.path))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keepPaths.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func displayID(of screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { $0.stringValue }
    }
}
