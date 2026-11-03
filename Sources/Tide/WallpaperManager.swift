import AppKit
import Combine

/// Affiche la pochette du morceau en cours sur le vrai écran de verrouillage de macOS.
///
/// Depuis macOS Sonoma, l'écran de verrouillage affiche le fond d'écran du bureau, et macOS y
/// dessine lui-même l'horloge et le lecteur « En lecture » (morceau suivant, barre de durée…).
/// Tide remplace donc le fond d'écran **uniquement pendant que la session est verrouillée**,
/// puis remet exactement celui d'origine dès le déverrouillage.
@MainActor
final class WallpaperManager {
    static let shared = WallpaperManager()

    private var cancellables = Set<AnyCancellable>()
    private var lastSettings: Settings?
    private var generation = 0
    private var isLocked = false
    /// Notre image est actuellement appliquée (il faudra restaurer).
    private var isApplied = false
    /// Images déjà générées pour le morceau en cours, par écran.
    private var prepared: [String: URL] = [:]
    private let renderQueue = DispatchQueue(label: "app.tide.wallpaper", qos: .userInitiated)
    private let folder: URL

    private static let originalsKey = "originalWallpapers"
    private static let storePlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    private var storeBackup: URL { folder.appendingPathComponent("Index.plist.backup") }

    private struct Settings: Equatable {
        var enabled: Bool
        var coverSize: Double
        var coverCenter: Double
        var blur: Double

        static var current: Settings {
            let d = UserDefaults.standard
            return Settings(
                enabled: d.bool(forKey: Prefs.wallpaperMode),
                coverSize: d.double(forKey: Prefs.coverSize),
                coverCenter: d.double(forKey: Prefs.coverCenter),
                blur: d.double(forKey: Prefs.backgroundBlur)
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

        // Si Tide a été fermé brutalement pendant un verrouillage, on remet le fond d'origine.
        if UserDefaults.standard.dictionary(forKey: Self.originalsKey) != nil
            || FileManager.default.fileExists(atPath: storeBackup.path) {
            isApplied = true
            restoreOriginal()
        }

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked() }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenUnlocked() }
        }

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
            .sink { [weak self] _ in self?.prepare() }
            .store(in: &cancellables)
    }

    /// Remet le fond d'écran d'origine (au déverrouillage, en quittant, ou si le mode est coupé).
    func restoreOriginal() {
        guard isApplied else { return }
        isApplied = false

        let saved = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        let needsStoreRestore = saved.values.contains { !Self.isPlainImage($0) }
        let fm = FileManager.default

        if needsStoreRestore, fm.fileExists(atPath: storeBackup.path) {
            // Fond animé/aérien : on remet la configuration complète de macOS telle quelle.
            _ = try? fm.removeItem(at: Self.storePlist)
            if (try? fm.copyItem(at: storeBackup, to: Self.storePlist)) != nil {
                Self.relaunchWallpaperAgent()
            }
        } else {
            for screen in NSScreen.screens {
                guard let id = Self.displayID(of: screen), let path = saved[id],
                      fm.fileExists(atPath: path) else { continue }
                try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
            }
        }

        UserDefaults.standard.removeObject(forKey: Self.originalsKey)
        try? fm.removeItem(at: storeBackup)
    }

    // MARK: - Verrouillage

    private func screenLocked() {
        isLocked = true
        applyIfPossible()
    }

    private func screenUnlocked() {
        isLocked = false
        restoreOriginal()
    }

    private func applyIfPossible() {
        guard isLocked, Settings.current.enabled, SpotifyController.shared.artwork != nil else { return }
        if prepared.isEmpty {
            prepare() // appliquera à la fin du rendu
        } else {
            setPrepared()
        }
    }

    private func setPrepared() {
        guard isLocked, !prepared.isEmpty else { return }
        backupOriginalsIfNeeded()
        isApplied = true
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen), let url = prepared[id] else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                    .allowClipping: true,
                ])
            } catch {
                NSLog("Tide – impossible d'appliquer l'image : %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Réactions

    private func artworkChanged(_ image: NSImage?) {
        if image == nil {
            prepared = [:]
            if isLocked { restoreOriginal() }
            return
        }
        prepare()
    }

    private func settingsChanged() {
        let settings = Settings.current
        guard settings != lastSettings else { return }
        lastSettings = settings
        if settings.enabled {
            prepare()
        } else {
            restoreOriginal()
        }
    }

    // MARK: - Rendu (à l'avance, pour que le changement au verrouillage soit instantané)

    private func prepare() {
        let settings = Settings.current
        guard settings.enabled,
              let image = SpotifyController.shared.artwork,
              let cover = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        generation += 1
        let gen = generation
        let layout = WallpaperRenderer.Layout(coverSize: settings.coverSize, coverCenter: settings.coverCenter, blur: settings.blur)
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
                // Nom unique : macOS ne recharge pas une image dont le chemin n'a pas changé.
                let url = folder.appendingPathComponent("tide-\(target.id)-\(UUID().uuidString.prefix(8)).jpg")
                if (try? data.write(to: url, options: .atomic)) != nil { files[target.id] = url }
            }

            Task { @MainActor in
                guard let self, gen == self.generation else {
                    files.values.forEach { try? FileManager.default.removeItem(at: $0) }
                    return
                }
                self.prepared = files
                self.cleanUp()
                // Verrouillé (morceau suivant pendant le verrouillage, ou premier rendu) → on applique.
                if self.isLocked { self.setPrepared() }
            }
        }
    }

    // MARK: - Sauvegarde du fond d'origine

    private func backupOriginalsIfNeeded() {
        guard !isApplied else { return }
        var saved: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !url.path.hasPrefix(folder.path) else { continue }
            saved[id] = url.path
        }
        UserDefaults.standard.set(saved, forKey: Self.originalsKey)

        let fm = FileManager.default
        try? fm.removeItem(at: storeBackup)
        if fm.fileExists(atPath: Self.storePlist.path) {
            try? fm.copyItem(at: Self.storePlist, to: storeBackup)
        }
    }

    private func cleanUp() {
        let keep = Set(prepared.values.map(\.standardizedFileURL.path))
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jpg" && !keep.contains(file.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Utilitaires

    /// Fond « simple » (une image) qu'on peut remettre directement, par opposition aux fonds
    /// aériens / dynamiques gérés par macOS, qu'on restaure via leur configuration complète.
    private static func isPlainImage(_ path: String) -> Bool {
        let systemManaged = path.contains("com.apple.wallpaper") || path.contains("/.wallpapers/")
            || path.contains("aerials") || path.contains("Aerial")
        let ext = (path as NSString).pathExtension.lowercased()
        return !systemManaged && ["jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp", "webp"].contains(ext)
    }

    private static func relaunchWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["-KILL", "WallpaperAgent"] // relancé aussitôt par macOS
        try? task.run()
    }

    private static func displayID(of screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { $0.stringValue }
    }
}
