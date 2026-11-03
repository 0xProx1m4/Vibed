import AppKit
import Combine
import CoreServices

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

/// Lit l'état de Spotify et le pilote.
///
/// Deux sources d'information :
/// 1. la notification que Spotify diffuse à chaque changement (aucune autorisation requise) ;
/// 2. AppleScript, interrogé chaque seconde (position exacte + commandes), qui nécessite
///    l'autorisation « Automatisation › Spotify ».
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
    @Published private(set) var access: Access = .unknown
    @Published private(set) var lastError: String?
    /// Position pendant que l'utilisateur fait glisser la barre de progression.
    @Published var scrubPosition: TimeInterval?

    private var position: TimeInterval = 0
    private var positionDate = Date()
    private var timer: Timer?
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: String?
    private var artworkCache: [String: NSImage] = [:]
    private var accessCheckInFlight = false

    private static let bundleID = "com.spotify.client"
    private static let separator = "\u{1F}"
    private static let statusScript = """
    if application "Spotify" is not running then return "NOTRUNNING"
    with timeout of 3 seconds
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
    end timeout
    """

    // MARK: - Cycle de vie

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

    /// Position interpolée (fluide entre deux lectures).
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

    /// Redemande l'autorisation à macOS (affiche la fenêtre « Tide souhaite contrôler Spotify »).
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

    // MARK: - Autorisation

    private func checkAccess(prompt: Bool) {
        guard !accessCheckInFlight else { return }
        accessCheckInFlight = true
        // AEDeterminePermissionToAutomateTarget bloque tant que la fenêtre est affichée :
        // jamais sur le thread principal.
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
                    break // Spotify pas encore lancé, etc. On réessaiera.
                }
            }
        }
    }

    // MARK: - Interne

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
            // Premier passage : on demande l'autorisation (une seule fenêtre système).
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

    /// Données envoyées par Spotify à chaque changement — fonctionne même sans autorisation.
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
        if newTrack != track { track = newTrack }
        if playing != isPlaying { isPlaying = playing }
        position = newPosition
        positionDate = Date()
        if lastError != nil { lastError = nil }
        loadArtworkIfNeeded(trackID: newTrack.id, url: artworkURL)
    }

    private func clear() {
        if track != nil { track = nil }
        if isPlaying { isPlaying = false }
        if artwork != nil { artwork = nil }
        artworkTrackID = nil
        artworkTask?.cancel()
    }

    // MARK: - Pochette

    private func loadArtworkIfNeeded(trackID: String, url: URL?) {
        guard trackID != artworkTrackID else { return }
        artworkTrackID = trackID
        artworkTask?.cancel()

        if let cached = artworkCache[trackID] { artwork = cached; return }

        artworkTask = Task { [weak self] in
            var imageURL = url
            if imageURL == nil { imageURL = await Self.oEmbedThumbnail(for: trackID) }
            guard let imageURL,
                  let (data, _) = try? await URLSession.shared.data(from: imageURL),
                  let image = NSImage(data: data),
                  !Task.isCancelled,
                  let self else { return }
            if self.artworkCache.count > 40 { self.artworkCache.removeAll() }
            self.artworkCache[trackID] = image
            if self.artworkTrackID == trackID { self.artwork = image }
        }
    }

    /// Pochette via l'API publique oEmbed de Spotify (sans compte ni clé).
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

    /// AppleScript (NSAppleScript) doit être utilisé sur le thread principal.
    private func execute(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "erreur inconnue"
            NSLog("Tide – erreur AppleScript %d : %@", code, message)
            if code == -1743 { access = .denied }
            lastError = "\(message) (\(code))"
        }
        return result
    }

    private static func number(_ string: String) -> Double? {
        Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}
