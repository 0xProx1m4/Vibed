import AppKit
import Combine
import CoreServices
import ImageIO

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

/// Reads Spotify's state and controls it.
///
/// Two sources of information:
/// 1. the notification Spotify broadcasts on every change (no permission required);
/// 2. AppleScript, polled every second (exact position + commands), which requires
///    the "Automation › Spotify" permission.
@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()

    enum Access: Equatable {
        case unknown, granted, denied
    }

    @Published private(set) var isRunning = false
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    /// Every artwork that lands in the cache (current or preloaded track), so the
    /// wallpaper can be prepared ahead of time.
    let artworkCached = PassthroughSubject<(trackID: String, image: NSImage, hiRes: Bool), Never>()
    @Published private(set) var access: Access = .unknown
    @Published private(set) var lastError: String?
    /// Position while the user drags the progress bar.
    @Published var scrubPosition: TimeInterval?
    /// Hovered position on the progress bar (0…1), for the time bubble.
    @Published var hoverProgress: Double?
    /// Known "liked" state per track (read via the Web API when the account is connected).
    @Published private var likedCache: [String: Bool] = [:]

    var isCurrentTrackLiked: Bool { track.flatMap { likedCache[$0.id] } ?? false }

    /// Without a connected account, the ♥ sends Spotify's "Like" shortcut (⌥⇧B),
    /// which requires the macOS permission to send keystrokes (Accessibility).
    var canLike: Bool { SpotifyWebAPI.shared.isConnected || CGPreflightPostEventAccess() }

    private var position: TimeInterval = 0
    private var positionDate = Date()
    private var timer: Timer?
    /// Already downloaded (decoded) artwork, per track.
    private var artworkCache: [String: NSImage] = [:]
    /// Tracks whose cached artwork is already the high-resolution version.
    private var hiResCached: Set<String> = []
    /// Insertion order in the cache, to evict the oldest artwork first.
    private var artworkCacheOrder: [String] = []
    /// A single download per track, shared between the current track and preloading.
    private var artworkLoads: [String: Task<Void, Never>] = [:]
    private var queueTask: Task<Void, Never>?
    private var lastQueueCheck = Date.distantPast
    /// Number of upcoming tracks whose artwork is kept ready.
    private static let prefetchCount = 5
    private static let artworkCacheLimit = 30
    private var accessCheckInFlight = false

    private static let bundleID = "com.spotify.client"
    private static let separator = "\u{1F}"
    private static let statusScript = """
    if application "Spotify" is not running then return "NOTRUNNING"
    with timeout of 3 seconds
        tell application "Spotify"
            set tideState to (player state as string)
            if tideState is "stopped" then return "STOPPED"
            set tideTrack to current track
            set tideSep to (character id 31)
            set tideArt to ""
            try
                set tideArt to artwork url of tideTrack
                if tideArt is missing value then set tideArt to ""
            end try
            set tideDuration to (duration of tideTrack) as string
            set tidePosition to (player position) as string
            return (id of tideTrack) & tideSep & (name of tideTrack) & tideSep & (artist of tideTrack) & tideSep & (album of tideTrack) & tideSep & tideArt & tideSep & tideDuration & tideSep & tidePosition & tideSep & tideState
        end tell
    end timeout
    """

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo ?? [:]
            Task { @MainActor in
                self?.applyNotification(info)
                self?.poll()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    /// Interpolated position (smooth between two polls).
    func position(at date: Date) -> TimeInterval {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(p, 0), track.duration)
    }

    // MARK: - Commands

    func requestLikePermission() {
        _ = CGRequestPostEventAccess()
    }

    /// Asks Spotify (Web API) whether the current track is in Liked Songs.
    func refreshLikedState() {
        guard let track, Self.isLikeable(track.id), SpotifyWebAPI.shared.isConnected else { return }
        let id = track.id
        Task { [weak self] in
            guard let liked = await SpotifyWebAPI.shared.isSaved(uri: id) else { return }
            self?.likedCache[id] = liked
        }
    }

    /// Adds / removes the track from Liked Songs.
    /// - Spotify account connected: via the Web API (reliable, and the real state is known).
    /// - Otherwise: Spotify shortcut ⌥⇧B sent directly to the app (state unknown).
    func toggleLike() {
        guard let track else { return }
        let id = track.id
        let newValue = !(likedCache[id] ?? false)

        if SpotifyWebAPI.shared.isConnected, Self.isLikeable(id) {
            likedCache[id] = newValue // update the UI immediately
            Task { [weak self] in
                let ok = await SpotifyWebAPI.shared.setSaved(newValue, uri: id)
                if !ok { self?.likedCache[id] = !newValue }
            }
            return
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return }
        guard CGPreflightPostEventAccess() else {
            requestLikePermission()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyB: CGKeyCode = 11
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyB, keyDown: isDown)
            event?.flags = [.maskAlternate, .maskShift]
            event?.postToPid(app.processIdentifier)
        }
        likedCache[id] = newValue
    }

    private static func isLikeable(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:track:") || uri.hasPrefix("spotify:episode:")
    }

    func playPause() {
        freezePosition()
        isPlaying.toggle()
        send("playpause")
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to time: TimeInterval) {
        position = time
        positionDate = Date()
        send("set player position to \(String(format: "%.2f", time))")
    }

    /// Asks macOS for permission again (shows the "Tide wants to control Spotify" prompt).
    func requestAccess() {
        accessCheckInFlight = false
        access = .unknown
        checkAccess(prompt: true)
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permission

    private func checkAccess(prompt: Bool) {
        guard !accessCheckInFlight else { return }
        accessCheckInFlight = true
        // AEDeterminePermissionToAutomateTarget blocks while the prompt is shown:
        // never on the main thread.
        let bundleID = Self.bundleID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let status: OSStatus = target.aeDesc.map {
                AEDeterminePermissionToAutomateTarget($0, typeWildCard, typeWildCard, prompt)
            } ?? OSStatus(procNotFound)

            Task { @MainActor in
                guard let self else { return }
                self.accessCheckInFlight = false
                switch status {
                case OSStatus(noErr):
                    self.access = .granted
                    self.poll()
                case OSStatus(errAEEventNotPermitted):
                    self.access = .denied
                case OSStatus(errAEEventWouldRequireUserConsent):
                    self.access = .unknown
                default:
                    break // Spotify not launched yet, etc. We'll retry.
                }
            }
        }
    }

    // MARK: - Internal

    private func freezePosition() {
        position = position(at: Date())
        positionDate = Date()
    }

    private func send(_ command: String) {
        guard isRunning, access == .granted else {
            if access != .granted { checkAccess(prompt: true) }
            return
        }
        _ = execute("tell application \"Spotify\" to \(command)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
        if running != isRunning { isRunning = running }
        guard running else { clear(); return }

        guard access == .granted else {
            // First pass: ask for permission (a single system prompt).
            if access == .unknown { checkAccess(prompt: true) }
            return
        }
        applyScript(execute(Self.statusScript)?.stringValue)
    }

    private func applyScript(_ result: String?) {
        guard let result else { return }
        guard result != "NOTRUNNING", result != "STOPPED" else { clear(); return }

        let parts = result.components(separatedBy: Self.separator)
        guard parts.count >= 8 else { return }

        update(
            track: Track(
                id: parts[0], title: parts[1], artist: parts[2], album: parts[3],
                duration: (Self.number(parts[5]) ?? 0) / 1000
            ),
            artworkURL: URL(string: parts[4]),
            playing: parts[7] == "playing",
            position: Self.number(parts[6]) ?? 0
        )
    }

    /// Data sent by Spotify on every change — works even without permission.
    private func applyNotification(_ info: [AnyHashable: Any]) {
        let state = (info["Player State"] as? String ?? "").lowercased()
        if state == "stopped" { clear(); return }
        guard let id = info["Track ID"] as? String, !id.isEmpty else { return }

        update(
            track: Track(
                id: id,
                title: info["Name"] as? String ?? "",
                artist: info["Artist"] as? String ?? "",
                album: info["Album"] as? String ?? "",
                duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
            ),
            artworkURL: nil,
            playing: state == "playing",
            position: (info["Playback Position"] as? NSNumber)?.doubleValue ?? position(at: Date())
        )
    }

    private func update(track newTrack: Track, artworkURL: URL?, playing: Bool, position newPosition: TimeInterval) {
        let trackChanged = newTrack.id != track?.id
        if newTrack != track { track = newTrack }
        if trackChanged { refreshLikedState() }
        if playing != isPlaying { isPlaying = playing }
        position = newPosition
        positionDate = Date()
        if lastError != nil { lastError = nil }
        // First the current track's artwork (often already cached → instant)…
        loadArtworkIfNeeded(trackID: newTrack.id, url: artworkURL)
        // …then fill in the next 5. Also every now and then, in case the queue changed.
        if trackChanged || Date().timeIntervalSince(lastQueueCheck) > 45 {
            prefetchUpcomingArtwork()
        }
    }

    private func clear() {
        if track != nil { track = nil }
        if isPlaying { isPlaying = false }
        if artwork != nil { artwork = nil }
    }

    // MARK: - Artwork

    private func loadArtworkIfNeeded(trackID: String, url: URL?) {
        // Cached (preloaded): show immediately.
        if let cached = artworkCache[trackID], artwork !== cached { artwork = cached }

        // Already downloading (preloading included): it will update the artwork
        // when it arrives. Or already high-resolution: nothing to do.
        guard artworkLoads[trackID] == nil, !hiResCached.contains(trackID) else { return }
        if artworkCache[trackID] != nil, url == nil { return }

        // Spotify's notification doesn't include the artwork URL, but the script run
        // right after does: wait for it rather than making an extra network lookup.
        if url == nil, access == .granted { return }

        startArtworkLoad(trackID: trackID, url: url)
    }

    private func startArtworkLoad(trackID: String, url: URL?) {
        artworkLoads[trackID] = Task { [weak self] in
            await self?.fetchArtwork(trackID: trackID, url: url)
            self?.artworkLoads[trackID] = nil
        }
    }

    /// Downloads the 640 px artwork (light, ready quickly) and, at the same time, the
    /// high-resolution version (2000 px) that replaces it as soon as it arrives. Each version is
    /// cached and shown if the track is the current one.
    private func fetchArtwork(trackID: String, url: URL?) async {
        var imageURL = url
        if imageURL == nil { imageURL = await Self.oEmbedThumbnail(for: trackID) }
        guard let imageURL else { return }

        async let hiRes = Self.downloadImage(Self.highResolutionURL(for: imageURL))
        if artworkCache[trackID] == nil, let quick = await Self.downloadImage(imageURL) {
            store(quick, for: trackID, hiRes: false)
        }
        if let best = await hiRes {
            store(best, for: trackID, hiRes: true)
        } else if artworkCache[trackID] != nil {
            hiResCached.insert(trackID) // Spotify has no HD version: the 640 px one will do
        }
    }

    private func store(_ image: NSImage, for trackID: String, hiRes: Bool) {
        if !hiRes, hiResCached.contains(trackID) { return } // the HD version arrived first
        if hiRes { hiResCached.insert(trackID) }
        artworkCacheOrder.removeAll { $0 == trackID }
        artworkCacheOrder.append(trackID)
        artworkCache[trackID] = image
        // Evict the oldest; the current and upcoming tracks are the most recent.
        while artworkCacheOrder.count > Self.artworkCacheLimit {
            let old = artworkCacheOrder.removeFirst()
            artworkCache[old] = nil
            hiResCached.remove(old)
        }
        if track?.id == trackID, artwork !== image { artwork = image }
        artworkCached.send((trackID, image, hiRes))
    }

    /// The cached artwork is the final version (HD, or there's no other one).
    func hasFinalArtwork(_ trackID: String) -> Bool { hiResCached.contains(trackID) }

    /// Keeps the artwork of the next 5 tracks in the queue ready (Spotify account
    /// connected). On first launch, all 5 are downloaded in parallel; then, on
    /// each track change, only the newcomer at the end of the window is missing.
    func prefetchUpcomingArtwork() {
        guard SpotifyWebAPI.shared.isConnected else { return }
        lastQueueCheck = Date()
        queueTask?.cancel()
        queueTask = Task { [weak self] in
            // Right after a skip, Spotify may briefly return the old queue:
            // ask again until it starts with the current track.
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 350_000_000) }
                guard !Task.isCancelled,
                      let queue = await SpotifyWebAPI.shared.queue(limit: Self.prefetchCount),
                      !Task.isCancelled, let self else { return }
                let isFresh = queue.current == nil || queue.current == self.track?.id
                if isFresh || attempt == 3 {
                    for (uri, url) in queue.upcoming
                    where self.artworkLoads[uri] == nil && !self.hiResCached.contains(uri) {
                        self.startArtworkLoad(trackID: uri, url: url)
                    }
                    return
                }
            }
        }
    }

    /// Spotify artwork URLs encode the size: …ab67616d0000b273… = 640 px,
    /// …ab67616d000082c1… = original size (often 2000 px).
    nonisolated private static func highResolutionURL(for url: URL) -> URL? {
        let string = url.absoluteString
        guard let range = string.range(of: "ab67616d0000[0-9a-fA-F]{4}", options: .regularExpression) else { return nil }
        let hiRes = string.replacingCharacters(in: range, with: "ab67616d000082c1")
        return hiRes == string ? nil : URL(string: hiRes)
    }

    /// Downloads and decodes the image off the main thread: it then displays
    /// without a hitch (a regular NSImage only decodes on first display).
    nonisolated private static func downloadImage(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return NSImage(data: data) }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Artwork via Spotify's public oEmbed API (no account or key needed).
    nonisolated private static func oEmbedThumbnail(for trackID: String) async -> URL? {
        // "spotify:track:abc" → https://open.spotify.com/track/abc
        let parts = trackID.split(separator: ":")
        guard parts.count >= 3, parts[1] != "local" else { return nil }
        let pageURL = "https://open.spotify.com/\(parts[1])/\(parts[2])"

        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: pageURL)]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumb = json["thumbnail_url"] as? String else { return nil }
        return URL(string: thumb)
    }

    // MARK: - AppleScript

    /// AppleScript (NSAppleScript) must be used on the main thread.
    private func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            NSLog("Tide – AppleScript error %d: %@", code, message)
            if code == -1743 { access = .denied }
            lastError = "\(message) (\(code))"
        }
        return result
    }

    private static func number(_ string: String) -> Double? {
        Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}
