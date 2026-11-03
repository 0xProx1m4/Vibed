import AppKit
import CryptoKit
import Network

/// Connexion au compte Spotify (API web) pour savoir si un morceau est déjà liké,
/// liker / retirer un like de façon fiable, et lire la file d'attente (pochettes préchargées).
///
/// Authentification « Authorization Code + PKCE » : pas de secret, pas de mot de passe stocké.
/// Le navigateur renvoie vers un mini serveur local (127.0.0.1) le temps de la connexion.
@MainActor
final class SpotifyWebAPI: ObservableObject {
    static let shared = SpotifyWebAPI()

    static let redirectPort: UInt16 = 43821
    static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/callback" }
    private static let scopes = "user-library-read user-library-modify user-read-playback-state"

    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var lastError: String?

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast
    private var refreshToken: String?
    private var listener: NWListener?
    private var pendingVerifier: String?
    private var pendingState: String?
    private let tokenFile: URL

    private var clientID: String {
        (UserDefaults.standard.string(forKey: Prefs.spotifyClientID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tide", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        tokenFile = support.appendingPathComponent("spotify-token")
        refreshToken = (try? String(contentsOf: tokenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if refreshToken?.isEmpty == true { refreshToken = nil }
        isConnected = refreshToken != nil
    }

    // MARK: - Connexion

    func connect() {
        guard !clientID.isEmpty else {
            lastError = "Colle d'abord le Client ID de ton app Spotify."
            return
        }
        lastError = nil

        let verifier = Self.randomURLSafe(byteCount: 64)
        let state = Self.randomURLSafe(byteCount: 16)
        pendingVerifier = verifier
        pendingState = state

        do {
            try startListener()
        } catch {
            lastError = "Le port \(Self.redirectPort) est déjà utilisé."
            return
        }

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { return }
        isConnecting = true
        NSWorkspace.shared.open(url)
    }

    func disconnect() {
        listener?.cancel()
        listener = nil
        accessToken = nil
        accessTokenExpiry = .distantPast
        setRefreshToken(nil)
        isConnected = false
        isConnecting = false
    }

    // MARK: - Bibliothèque

    /// `true` si le morceau est dans les Titres likés, `nil` si on ne sait pas (non connecté, erreur…).
    func isSaved(uri: String) async -> Bool? {
        guard let data = await call("GET", path: "/me/library/contains", uris: [uri]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [Bool])?.first
    }

    /// Ajoute (`true`) ou retire (`false`) le morceau des Titres likés.
    func setSaved(_ saved: Bool, uri: String) async -> Bool {
        await call(saved ? "PUT" : "DELETE", path: "/me/library", uris: [uri]) != nil
    }

    // MARK: - File d'attente

    /// Le jeton actuel n'a pas le droit de lire la file (compte connecté avant l'ajout de ce droit).
    @Published private(set) var queueForbidden = false

    /// Prochains morceaux de la file, avec l'URL de leur pochette (640 px).
    /// Vide si le compte n'est pas connecté ou s'il faut se reconnecter pour donner ce droit.
    func upcomingArtwork(limit: Int) async -> [(uri: String, url: URL)] {
        guard !queueForbidden,
              let data = await call("GET", path: "/me/player/queue", quiet: true),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queue = json["queue"] as? [[String: Any]] else { return [] }

        return queue.prefix(limit).compactMap { item in
            guard let uri = item["uri"] as? String,
                  let album = item["album"] as? [String: Any],
                  let images = album["images"] as? [[String: Any]] else { return nil }
            // Les images vont de la plus grande à la plus petite ; on prend la 640 px.
            let pick = images.first { ($0["width"] as? Int) == 640 } ?? images.first
            guard let string = pick?["url"] as? String, let url = URL(string: string) else { return nil }
            return (uri, url)
        }
    }

    private func call(_ method: String, path: String, uris: [String]? = nil, quiet: Bool = false) async -> Data? {
        guard let token = await validAccessToken() else { return nil }

        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if let uris {
            components.queryItems = [URLQueryItem(name: "uris", value: uris.joined(separator: ","))]
        }
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" { request.httpBody = Data() } // Content-Length: 0

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 401 { accessToken = nil }
        if http.statusCode == 403, path == "/me/player/queue" { queueForbidden = true }
        guard (200..<300).contains(http.statusCode) else {
            guard !quiet else { return nil }
            let body = String(data: data, encoding: .utf8) ?? ""
            NSLog("Tide – API Spotify %@ %@ → %d %@", method, path, http.statusCode, body)
            lastError = "API Spotify : erreur \(http.statusCode)"
            return nil
        }
        return data
    }

    // MARK: - Jetons

    private func validAccessToken() async -> String? {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refreshToken, !clientID.isEmpty else { return nil }
        let status = await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        if status == 400 { disconnect() } // jeton révoqué ou expiré : il faut se reconnecter
        return status == 200 ? accessToken : nil
    }

    private func exchange(code: String, verifier: String) async {
        let status = await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        isConnecting = false
        isConnected = status == 200 && refreshToken != nil
        if isConnected {
            lastError = nil
            queueForbidden = false
            SpotifyController.shared.refreshLikedState()
        }
    }

    /// Renvoie le code HTTP (0 si pas de réseau).
    private func requestToken(_ form: [String: String]) async -> Int {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(form)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            lastError = "Impossible de joindre Spotify."
            return 0
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard http.statusCode == 200, let token = json["access_token"] as? String else {
            lastError = (json["error_description"] as? String) ?? "Spotify a refusé la connexion (\(http.statusCode))."
            return http.statusCode
        }
        accessToken = token
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        accessTokenExpiry = Date().addingTimeInterval(lifetime - 60)
        if let newRefresh = json["refresh_token"] as? String { setRefreshToken(newRefresh) }
        return 200
    }

    private func setRefreshToken(_ token: String?) {
        refreshToken = token
        if let token {
            try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        } else {
            try? FileManager.default.removeItem(at: tokenFile)
        }
    }

    // MARK: - Serveur local de redirection

    private enum CallbackResult { case ignored, success, failure }

    private func startListener() throws {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.redirectPort)!)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handle(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                let result = self?.handleCallback(request) ?? .ignored
                let body: String
                switch result {
                case .success: body = "<h2>Tide est connecté à Spotify ✓</h2><p>Tu peux fermer cet onglet.</p>"
                case .failure: body = "<h2>Connexion échouée</h2><p>Réessaie depuis le menu Tide.</p>"
                case .ignored: body = ""
                }
                let html = """
                <!doctype html><html><head><meta charset="utf-8"><title>Tide</title></head>
                <body style="font-family:-apple-system,sans-serif;text-align:center;padding:80px;color:#222">\(body)</body></html>
                """
                let status = result == .ignored ? "404 Not Found" : "200 OK"
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func handleCallback(_ request: String) -> CallbackResult {
        guard let firstLine = request.split(separator: "\r\n").first else { return .ignored }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1" + String(parts[1])),
              components.path == "/callback" else { return .ignored }

        listener?.cancel()
        listener = nil

        var items: [String: String] = [:]
        for item in components.queryItems ?? [] { items[item.name] = item.value ?? "" }

        guard let code = items["code"], items["state"] == pendingState, let verifier = pendingVerifier else {
            isConnecting = false
            lastError = items["error"].map { "Spotify a refusé : \($0)" } ?? "Connexion annulée."
            return .failure
        }
        pendingVerifier = nil
        pendingState = nil
        Task { await exchange(code: code, verifier: verifier) }
        return .success
    }

    // MARK: - Utilitaires

    private static func randomURLSafe(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
