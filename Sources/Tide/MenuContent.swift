import SwiftUI

/// Petit panneau de la barre des menus.
struct MenuContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @AppStorage(Prefs.autoLockMinutes) private var autoLockMinutes = 0
    @AppStorage(Prefs.lockOnScreenSleep) private var lockOnScreenSleep = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowPlaying

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
