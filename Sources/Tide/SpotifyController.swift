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
    /// Position survolée sur la barre de progression (0…1), pour la bulle de temps.
    @Published var hoverProgress: Double?
    /// État « liké » connu par morceau (lu via l'API web si le compte est connecté).
    @Published private var likedCache: [String: Bool] = [:]

    var isCurrentTrackLiked: Bool { track.flatMap { likedCache[$0.id] } ?? false }

    /// Sans compte connecté, le ♥ envoie le raccourci « J'aime » de Spotify (⌥⇧B),
    /// ce qui demande l'autorisation macOS d'envoyer des touches (Accessibilité).
    var canLike: Bool { SpotifyWebAPI.shared.isConnected || CGPreflightPostEventAccess() }

    private var position: TimeInterval = 0
    private var positionDate = Date()
    private var timer: Timer?
    private var artworkTask: Task<Void, Never>?
    private var artworkTrackID: String?
    /// Le chargement en cours part de la vraie URL (et non d'une recherche oEmbed).
    private var artworkHasURL = false
    private var artworkCache: [String: NSImage] = [:]
    private var prefetchTask: Task<Void, Never>?
    /// Morceaux dont la pochette est en cours de préchargement.
    private var prefetching: Set<String> = []
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

    func requestLikePermission() {
        _ = CGRequestPostEventAccess()
    }

    /// Demande à Spotify (API web) si le morceau en cours est dans les Titres likés.
    func refreshLikedState() {
        guard let track, Self.isLikeable(track.id), SpotifyWebAPI.shared.isConnected else { return }
        let id = track.id
        Task { [weak self] in
            guard let liked = await SpotifyWebAPI.shared.isSaved(uri: id) else { return }
            self?.likedCache[id] = liked
        }
    }

    /// Ajoute / retire le morceau des Titres likés.
    /// - Compte Spotify connecté : via l'API web (fiable, et l'état réel est connu).
    /// - Sinon : raccourci Spotify ⌥⇧B envoyé directement à l'app (état inconnu).
    func toggleLike() {
        guard let track else { return }
        let id = track.id
        let newValue = !(likedCache[id] ?? false)

        if SpotifyWebAPI.shared.isConnected, Self.isLikeable(id) {
            likedCache[id] = newValue // affichage immédiat
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
        let trackChanged = newTrack.id != track?.id
        if newTrack != track { track = newTrack }
        if trackChanged {
            refreshLikedState()
            prefetchUpcomingArtwork()
        }
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
        // Déjà en cours pour ce morceau : on ne relance que si on reçoit enfin la vraie URL
        // alors qu'on était parti sur la recherche oEmbed (plus lente).
        if trackID == artworkTrackID, url == nil || artworkHasURL { return }

        // La notification de Spotify n'a pas l'URL de la pochette, mais le script lancé
        // juste après l'a : on l'attend plutôt que de faire une recherche réseau en plus.
        if url == nil, access == .granted, artworkCache[trackID] == nil {
            return
        }

        artworkTrackID = trackID
        artworkHasURL = url != nil
        artworkTask?.cancel()

        if let cached = artworkCache[trackID] { artwork = cached; return }

        artworkTask = Task { [weak self] in
            var imageURL = url
            if imageURL == nil { imageURL = await Self.oEmbedThumbnail(for: trackID) }
            guard let imageURL, !Task.isCancelled else { return }

            // 1. Pochette normale (640 px, légère) affichée tout de suite…
            let hiResURL = Self.highResolutionURL(for: imageURL)
            async let hiResDownload = Self.downloadImage(hiResURL)
            if let quick = await Self.downloadImage(imageURL), !Task.isCancelled, let self,
               self.artworkTrackID == trackID {
                self.artwork = quick
            }

            // 2. …puis remplacée par la version haute définition (2000 px) si Spotify l'a.
            let best = await hiResDownload
            guard !Task.isCancelled, let self, self.artworkTrackID == trackID else { return }
            if let best { self.artwork = best }
            if let image = best ?? self.artwork { self.cache(image, for: trackID) }
        }
    }

    private func cache(_ image: NSImage, for trackID: String) {
        if artworkCache.count > 40 { artworkCache.removeAll() }
        artworkCache[trackID] = image
    }

    /// Télécharge à l'avance les pochettes des prochains morceaux de la file (compte Spotify
    /// connecté) : au changement de morceau, la pochette est déjà là et s'affiche tout de suite.
    private func prefetchUpcomingArtwork() {
        guard SpotifyWebAPI.shared.isConnected else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            // Laisse d'abord passer le chargement de la pochette du morceau en cours.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let upcoming = await SpotifyWebAPI.shared.upcomingArtwork(limit: 3)
            for (uri, url) in upcoming {
                guard !Task.isCancelled, let self,
                      self.artworkCache[uri] == nil, !self.prefetching.contains(uri) else { continue }
                self.prefetching.insert(uri)
                var image = await Self.downloadImage(Self.highResolutionURL(for: url))
                if image == nil { image = await Self.downloadImage(url) }
                self.prefetching.remove(uri)
                if let image, self.artworkCache[uri] == nil { self.cache(image, for: uri) }
            }
        }
    }

    /// Les URL de pochette Spotify encodent la taille : …ab67616d0000b273… = 640 px,
    /// …ab67616d000082c1… = taille d'origine (souvent 2000 px).
    nonisolated private static func highResolutionURL(for url: URL) -> URL? {
        let string = url.absoluteString
        guard let range = string.range(of: "ab67616d0000[0-9a-fA-F]{4}", options: .regularExpression) else { return nil }
        let hiRes = string.replacingCharacters(in: range, with: "ab67616d000082c1")
        return hiRes == string ? nil : URL(string: hiRes)
    }

    /// Télécharge et décode l'image hors du thread principal : elle s'affiche ensuite
    /// sans à-coup (une NSImage ordinaire ne se décode qu'au premier affichage).
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
