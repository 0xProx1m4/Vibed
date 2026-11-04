import AppKit
import Combine

/// Shows the current track's artwork on the real macOS lock screen.
///
/// Since macOS Sonoma, the lock screen displays the desktop wallpaper, and macOS itself
/// draws the clock and the "Now Playing" player on it (next track, progress bar…).
/// So Tide replaces the wallpaper **only while the session is locked**,
/// then restores the exact original one as soon as it's unlocked.
@MainActor
final class WallpaperManager {
    static let shared = WallpaperManager()

    private var cancellables = Set<AnyCancellable>()
    private var lastSettings: Settings?
    private var generation = 0
    private var isLocked = false
    /// Our image is currently applied (it will need to be restored).
    private var isApplied = false
    /// Images already generated for the current track, per display.
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

    // MARK: - Lifecycle

    func start() {
        lastSettings = .current

        // If Tide was killed while locked, restore the original wallpaper.
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

    /// Restores the original wallpaper (on unlock, on quit, or when the mode is turned off).
    func restoreOriginal() {
        guard isApplied else { return }
        isApplied = false

        let saved = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
        let needsStoreRestore = saved.values.contains { !Self.isPlainImage($0) }
        let fm = FileManager.default

        if needsStoreRestore, fm.fileExists(atPath: storeBackup.path) {
            // Animated/aerial wallpaper: restore macOS's full configuration as-is.
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

    // MARK: - Locking

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
            prepare() // will apply once rendering finishes
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
                NSLog("Tide – unable to apply the image: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Reactions

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

    // MARK: - Rendering (ahead of time, so the switch on lock is instant)

    private func prepare() {
        let settings = Settings.current
        guard settings.enabled,
              let image = SpotifyController.shared.artwork,
              let cover = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        generation += 1
        let gen = generation
        let layout = WallpaperRenderer.Layout(coverSize: settings.coverSize, coverCenter: settings.coverCenter, blur: settings.blur)
        // The main display is where macOS shows the clock: it's the only one that gets the card.
        let mainID = NSScreen.screens.first.flatMap(Self.displayID(of:))
        let targets: [(id: String, size: CGSize, main: Bool)] = NSScreen.screens.compactMap { screen in
            guard let id = Self.displayID(of: screen) else { return nil }
            let scale = screen.backingScaleFactor
            return (id, CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale), id == mainID)
        }
        let folder = self.folder

        renderQueue.async { [weak self] in
            var files: [String: URL] = [:]
            for target in targets {
                guard let data = WallpaperRenderer.render(cover: cover, pixelSize: target.size, layout: layout, drawsCard: target.main) else { continue }
                // Unique name: macOS doesn't reload an image whose path hasn't changed.
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
                // Locked (next track while locked, or first render) → apply.
                if self.isLocked { self.setPrepared() }
            }
        }
    }

    // MARK: - Backing up the original wallpaper

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

    // MARK: - Utilities

    /// "Plain" wallpaper (a single image) that can be restored directly, as opposed to
    /// aerial / dynamic wallpapers managed by macOS, which are restored via their full configuration.
    private static func isPlainImage(_ path: String) -> Bool {
        let systemManaged = path.contains("com.apple.wallpaper") || path.contains("/.wallpapers/")
            || path.contains("aerials") || path.contains("Aerial")
        let ext = (path as NSString).pathExtension.lowercased()
        return !systemManaged && ["jpg", "jpeg", "png", "heic", "tif", "tiff", "gif", "bmp", "webp"].contains(ext)
    }

    private static func relaunchWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["-KILL", "WallpaperAgent"] // relaunched immediately by macOS
        try? task.run()
    }

    private static func displayID(of screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { $0.stringValue }
    }
}
