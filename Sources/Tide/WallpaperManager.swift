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
    /// Backgrounds already generated per track (current, previous and next 5), to apply them
    /// without waiting for a render when the track changes.
    private struct Rendered {
        var files: [String: URL]
        var final: Bool
    }
    private var rendered: [String: Rendered] = [:]
    private var renderedOrder: [String] = []
    private var prerendering: Set<String> = []
    private static let renderedLimit = 10
    private let renderQueue = DispatchQueue(label: "app.tide.wallpaper", qos: .userInitiated)
    /// Separate, lower-priority queue: ahead-of-time renders never delay
    /// the current track's render.
    private let prerenderQueue = DispatchQueue(label: "app.tide.wallpaper.prerender", qos: .utility)
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
        /// The sharp artwork is shown by the Tide bar (instant): the wallpaper
        /// then only contains the background.
        var coverInOverlay: Bool

        static var current: Settings {
            let d = UserDefaults.standard
            return Settings(
                enabled: d.bool(forKey: Prefs.wallpaperMode),
                coverSize: d.double(forKey: Prefs.coverSize),
                coverCenter: d.double(forKey: Prefs.coverCenter),
                blur: d.double(forKey: Prefs.backgroundBlur),
                coverInOverlay: d.bool(forKey: Prefs.lockScreenBar) && SkyLight.isAvailable
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
            .receive(on: RunLoop.main)
            .sink { [weak self] image in self?.artworkChanged(image) }
            .store(in: &cancellables)

        SpotifyController.shared.artworkCached
            .receive(on: RunLoop.main)
            .sink { [weak self] item in self?.prerender(trackID: item.trackID, image: item.image, final: item.hiRes) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.invalidateRendered(); self?.prepare() }
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

    // MARK: - Timing

    /// Log of background changes while locked (last 60), to see where
    /// the time goes: `~/Library/Application Support/Tide/wallpaper-timing.txt`.
    private var timingLines: [String] = []
    private var lastArtworkChange = Date()

    private func logTiming(_ message: String) {
        let elapsed = Int(Date().timeIntervalSince(lastArtworkChange) * 1000)
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        timingLines.append("\(stamp)  +\(elapsed) ms  \(message)")
        if timingLines.count > 60 { timingLines.removeFirst(timingLines.count - 60) }
        let file = folder.deletingLastPathComponent().appendingPathComponent("wallpaper-timing.txt")
        try? (timingLines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
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
        lastArtworkChange = Date()
        if image == nil {
            prepared = [:]
            if isLocked { restoreOriginal() }
            return
        }
        let id = SpotifyController.shared.track?.id
        // Background already ready (prepared ahead of time): applied right away, no render.
        if let id, let ready = rendered[id] {
            generation += 1 // an in-flight render for another track must no longer apply
            prepared = ready.files
            if isLocked {
                setPrepared()
                logTiming("artwork \(ready.final ? "HD" : "640") → background already ready, handed to macOS")
            }
            if ready.final || !SpotifyController.shared.hasFinalArtwork(id) { return }
        } else if isLocked {
            let web = SpotifyWebAPI.shared
            let prefetch = !web.isConnected ? "Spotify account not connected"
                : web.queueForbidden ? "Spotify reconnection needed" : "active"
            logTiming("artwork \(id.map(SpotifyController.shared.hasFinalArtwork) == true ? "HD" : "640") → background NOT ready, rendering… (preloading: \(prefetch))")
        }
        prepare()
    }

    private func settingsChanged() {
        let settings = Settings.current
        guard settings != lastSettings else { return }
        lastSettings = settings
        invalidateRendered()
        if settings.enabled {
            prepare()
        } else {
            restoreOriginal()
        }
    }

    // MARK: - Rendering (ahead of time, so the switch on lock is instant)

    private struct Target {
        let id: String
        let size: CGSize
        let drawsCard: Bool
    }

    private func renderSetup() -> (layout: WallpaperRenderer.Layout, targets: [Target])? {
        let settings = Settings.current
        guard settings.enabled else { return nil }
        let layout = WallpaperRenderer.Layout(coverSize: settings.coverSize, coverCenter: settings.coverCenter, blur: settings.blur)
        // The main display is where macOS shows the clock: it's the only one that gets the card.
        let mainID = NSScreen.screens.first.flatMap(Self.displayID(of:))
        let targets: [Target] = NSScreen.screens.compactMap { screen in
            guard let id = Self.displayID(of: screen) else { return nil }
            let scale = screen.backingScaleFactor
            return Target(id: id, size: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale),
                          drawsCard: id == mainID && !settings.coverInOverlay)
        }
        return (layout, targets)
    }

    nonisolated private static func renderFiles(cover: CGImage, layout: WallpaperRenderer.Layout,
                                                targets: [Target], folder: URL) -> [String: URL] {
        var files: [String: URL] = [:]
        for target in targets {
            guard let data = WallpaperRenderer.render(cover: cover, pixelSize: target.size, layout: layout, drawsCard: target.drawsCard) else { continue }
            // Unique name: macOS doesn't reload an image whose path hasn't changed.
            let url = folder.appendingPathComponent("tide-\(target.id)-\(UUID().uuidString.prefix(8)).jpg")
            if (try? data.write(to: url, options: .atomic)) != nil { files[target.id] = url }
        }
        return files
    }

    /// Renders the background for the current track.
    private func prepare() {
        guard let setup = renderSetup(),
              let image = SpotifyController.shared.artwork,
              let cover = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        generation += 1
        let gen = generation
        let trackID = SpotifyController.shared.track?.id
        let final = trackID.map(SpotifyController.shared.hasFinalArtwork) ?? false
        let folder = self.folder

        renderQueue.async { [weak self] in
            let start = Date()
            let files = Self.renderFiles(cover: cover, layout: setup.layout, targets: setup.targets, folder: folder)
            let renderTime = Date().timeIntervalSince(start)
            Task { @MainActor in
                guard let self else { return }
                if let trackID { self.remember(files, for: trackID, final: final) }
                guard gen == self.generation else { self.cleanUp(); return }
                self.prepared = files
                self.cleanUp()
                // Locked (next track while locked, or first render) → apply.
                if self.isLocked {
                    self.setPrepared()
                    self.logTiming("background rendered in \(Int(renderTime * 1000)) ms, handed to macOS")
                }
            }
        }
    }

    /// Renders an upcoming track's background ahead of time, as soon as its artwork is cached.
    private func prerender(trackID: String, image: NSImage, final: Bool) {
        // The current track goes through `prepare()`; a temporary 640 px isn't worth a render.
        guard final, trackID != SpotifyController.shared.track?.id,
              rendered[trackID]?.final != true, !prerendering.contains(trackID),
              let setup = renderSetup(),
              let cover = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        prerendering.insert(trackID)
        let folder = self.folder

        prerenderQueue.async { [weak self] in
            let files = Self.renderFiles(cover: cover, layout: setup.layout, targets: setup.targets, folder: folder)
            Task { @MainActor in
                guard let self else { return }
                self.prerendering.remove(trackID)
                self.remember(files, for: trackID, final: true)
                self.cleanUp()
                // Became the current track during the render, with no final background: use it.
                if SpotifyController.shared.track?.id == trackID, self.prepared != files {
                    self.generation += 1
                    self.prepared = files
                    if self.isLocked { self.setPrepared() }
                }
            }
        }
    }

    private func remember(_ files: [String: URL], for trackID: String, final: Bool) {
        guard !files.isEmpty else { return }
        if rendered[trackID]?.final == true, !final { return }
        rendered[trackID] = Rendered(files: files, final: final)
        renderedOrder.removeAll { $0 == trackID }
        renderedOrder.append(trackID)
        let current = SpotifyController.shared.track?.id
        while renderedOrder.count > Self.renderedLimit,
              let old = renderedOrder.first(where: { $0 != current }) {
            renderedOrder.removeAll { $0 == old }
            rendered[old] = nil
        }
    }

    /// Settings or displays changed: the prepared backgrounds are no longer valid.
    private func invalidateRendered() {
        rendered = [:]
        renderedOrder = []
        prerendering = []
        cleanUp()
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
        let inUse = prepared.values.map(\.standardizedFileURL.path)
            + rendered.values.flatMap { $0.files.values.map(\.standardizedFileURL.path) }
        let keep = Set(inUse)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jpg" && !keep.contains(file.standardizedFileURL.path) {
            // A render that just finished may not be recorded yet: leave it.
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < 30 { continue }
            try? fm.removeItem(at: file)
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
