import AppKit
import Combine

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let duration: TimeInterval
}

/// Lit l'état de Spotify et le pilote via AppleScript (aucune clé d'API nécessaire).
@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()

    @Published private(set) var isRunning = false
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?

    private var position: TimeInterval = 0
    private var positionDate = Date()
    private var timer: Timer?
    private var pollInFlight = false
    private var artworkTask: Task<Void, Never>?
    private var artworkCache: [URL: NSImage] = [:]
    private let scriptQueue = DispatchQueue(label: "app.tide.applescript", qos: .userInitiated)

    private static let bundleID = "com.spotify.client"
    nonisolated private static let separator = "\u{1F}"
    nonisolated private static let statusScript = """
    if application "Spotify" is not running then return "NOTRUNNING"
    tell application "Spotify"
        set st to player state as string
        if st is "stopped" then return "STOPPED"
        set t to current track
        set d to character id 31
        set art to ""
        try
            set art to artwork url of t
            if art is missing value then set art to ""
        end try
        return (id of t) & d & (name of t) & d & (artist of t) & d & (album of t) & d & art & d & ((duration of t) as string) & d & ((player position) as string) & d & st
    end tell
    """

    // MARK: - Cycle de vie

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Spotify publie une notification à chaque changement de lecture → mise à jour instantanée
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    /// Position interpolée (fluide entre deux lectures AppleScript).
    func position(at date: Date) -> TimeInterval {
        guard let track else { return 0 }
        let p = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return min(max(p, 0), track.duration)
    }

    // MARK: - Commandes

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

    // MARK: - Interne

    private func freezePosition() {
        position = position(at: Date())
        positionDate = Date()
    }

    private func send(_ command: String) {
        guard isRunning else { return }
        let source = "tell application \"Spotify\" to \(command)"
        scriptQueue.async { [weak self] in
            _ = Self.execute(source)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.poll()
            }
        }
    }

    private func poll() {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
        if running != isRunning { isRunning = running }
        guard running else { clear(); return }
        guard !pollInFlight else { return }
        pollInFlight = true

        scriptQueue.async { [weak self] in
            let result = Self.execute(Self.statusScript)?.stringValue
            Task { @MainActor in
                self?.pollInFlight = false
                self?.apply(result)
            }
        }
    }

    private func apply(_ result: String?) {
        guard let result else { return } // erreur (ex. permission refusée) : on garde l'état
        guard result != "NOTRUNNING", result != "STOPPED" else { clear(); return }

        let parts = result.components(separatedBy: Self.separator)
        guard parts.count >= 8 else { return }

        let newTrack = Track(
            id: parts[0],
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            artworkURL: URL(string: parts[4]),
            duration: (Self.number(parts[5]) ?? 0) / 1000
        )
        if newTrack != track {
            let artworkChanged = newTrack.artworkURL != track?.artworkURL
            track = newTrack
            if artworkChanged { loadArtwork(newTrack.artworkURL) }
        }

        let playing = parts[7] == "playing"
        if playing != isPlaying { isPlaying = playing }
        position = Self.number(parts[6]) ?? 0
        positionDate = Date()
    }

    private func clear() {
        if track != nil { track = nil }
        if isPlaying { isPlaying = false }
        if artwork != nil { artwork = nil }
    }

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        guard let url else { artwork = nil; return }
        if let cached = artworkCache[url] { artwork = cached; return }

        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data),
                  !Task.isCancelled,
                  let self else { return }
            if self.artworkCache.count > 40 { self.artworkCache.removeAll() }
            self.artworkCache[url] = image
            self.artwork = image
        }
    }

    /// AppleScript formate les nombres selon la langue (virgule en français).
    nonisolated private static func number(_ string: String) -> Double? {
        Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    nonisolated private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Tide – erreur AppleScript : %@", error) }
        return result
    }
}
