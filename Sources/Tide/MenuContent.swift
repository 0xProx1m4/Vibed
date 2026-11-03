import SwiftUI

/// Petit panneau de la barre des menus.
struct MenuContent: View {
    /// Réglages de l'écran verrouillé (pochette, barre, taille, position, flou).
    /// Masqués pour l'instant : passe à `true` pour les réafficher dans le menu.
    private static let showsCustomization = false

    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var webAPI = SpotifyWebAPI.shared
    @AppStorage(Prefs.spotifyClientID) private var clientID = ""
    @AppStorage(Prefs.wallpaperMode) private var wallpaperMode = true
    @AppStorage(Prefs.lockScreenBar) private var lockScreenBar = true
    @AppStorage(Prefs.coverSize) private var coverSize = 0.38
    @AppStorage(Prefs.coverCenter) private var coverCenter = 0.44
    @AppStorage(Prefs.backgroundBlur) private var backgroundBlur = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowPlaying

            accessBanner

            if Self.showsCustomization {
                customization

                Divider()
            }

            spotifyAccount

            Divider()

            Button("Quitter Tide") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    private var customization: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Écran de verrouillage macOS")
            Toggle("Pochette sur l'écran verrouillé", isOn: $wallpaperMode)
            Toggle("Barre Liquid Glass sur l'écran verrouillé", isOn: $lockScreenBar)
            if wallpaperMode {
                Text("Ton fond d'écran n'est jamais modifié pendant que tu utilises le Mac. Verrouille avec ⌃⌘Q pour voir le résultat.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                labeledSlider("Taille", value: $coverSize, range: 0.25...0.45)
                labeledSlider("Position", value: $coverCenter, range: 0.36...0.52)
                labeledSlider("Flou", value: $backgroundBlur, range: 0...1)
            }
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var spotifyAccount: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Compte Spotify (bouton ♥)")
            if webAPI.isConnected {
                HStack {
                    Label("Connecté", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Se déconnecter") { webAPI.disconnect() }
                }
                .font(.system(size: 12))
                if webAPI.queueForbidden {
                    Text("Reconnecte-toi (Se déconnecter, puis Se connecter) pour que Tide précharge les pochettes des prochains morceaux.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Pour que le ♥ soit rempli quand un morceau est déjà liké :\n1. developer.spotify.com/dashboard → Create app\n2. Redirect URI : \(SpotifyWebAPI.redirectURI)\n3. Coche « Web API », enregistre, copie le Client ID ici :")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    Button(webAPI.isConnecting ? "Connexion…" : "Se connecter à Spotify") { webAPI.connect() }
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Ouvrir le dashboard") {
                        NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.system(size: 12))
                if !spotify.canLike {
                    Button("Ou : ♥ sans compte (autorisation Accessibilité)") {
                        spotify.requestLikePermission()
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
            if let error = webAPI.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 52, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var accessBanner: some View {
        if spotify.isRunning && spotify.access != .granted {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    spotify.access == .denied
                        ? "Tide n'a pas le droit de contrôler Spotify."
                        : "Tide a besoin d'accéder à Spotify.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

                if spotify.access == .denied {
                    Text("Réglages Système › Confidentialité et sécurité › Automatisation › Tide → coche Spotify.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ouvrir les réglages") { spotify.openAutomationSettings() }
                } else {
                    Button("Autoriser l'accès à Spotify") { spotify.requestAccess() }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: 10)
        } else if let error = spotify.lastError, spotify.track == nil {
            Text("Spotify : \(error)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var nowPlaying: some View {
        HStack(spacing: 12) {
            Group {
                if let art = spotify.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(spotify.track?.title ?? (spotify.isRunning ? "Rien en lecture" : "Spotify n'est pas ouvert"))
                    .font(.system(size: 13, weight: .semibold))
                Text(spotify.track?.artist ?? "Tide")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Spacer(minLength: 0)

            if spotify.track != nil {
                Button { spotify.playPause() } label: {
                    Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableStyle(highlight: .circle))
            }
        }
    }
}
