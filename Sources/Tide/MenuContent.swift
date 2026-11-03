import SwiftUI

/// Petit panneau de la barre des menus.
struct MenuContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @AppStorage(Prefs.autoLockMinutes) private var autoLockMinutes = 0
    @AppStorage(Prefs.lockOnScreenSleep) private var lockOnScreenSleep = false
    @AppStorage(Prefs.wallpaperMode) private var wallpaperMode = true
    @AppStorage(Prefs.restoreWallpaperWhenIdle) private var restoreWhenIdle = true
    @AppStorage(Prefs.coverSize) private var coverSize = 0.34
    @AppStorage(Prefs.coverCenter) private var coverCenter = 0.53

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowPlaying

            accessBanner

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Écran de verrouillage macOS")
                Toggle("Pochette en fond d'écran", isOn: $wallpaperMode)
                if wallpaperMode {
                    Toggle("Remettre mon fond quand rien ne joue", isOn: $restoreWhenIdle)
                    labeledSlider("Taille", value: $coverSize, range: 0.2...0.5)
                    labeledSlider("Position", value: $coverCenter, range: 0.35...0.7)
                }
            }
            .font(.system(size: 12))

            Divider()

            sectionTitle("Écran Tide")

            Button {
                LockScreenManager.shared.lock()
            } label: {
                HStack {
                    Image(systemName: "lock.fill")
                    Text("Verrouiller maintenant")
                    Spacer()
                    Text("⌃⌥⌘L").foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .liquidGlass(cornerRadius: 12)
            }
            .buttonStyle(PressableStyle())

            VStack(alignment: .leading, spacing: 10) {
                Picker("Verrouillage auto", selection: $autoLockMinutes) {
                    Text("Jamais").tag(0)
                    Text("1 min").tag(1)
                    Text("2 min").tag(2)
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("15 min").tag(15)
                }
                Toggle("Verrouiller quand l'écran s'éteint", isOn: $lockOnScreenSleep)
            }
            .font(.system(size: 12))

            Divider()

            Button("Quitter Tide") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
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
                .buttonStyle(PressableStyle())
            }
        }
    }
}
