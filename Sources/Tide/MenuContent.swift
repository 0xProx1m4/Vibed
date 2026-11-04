import SwiftUI

/// Small menu bar panel.
struct MenuContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var webAPI = SpotifyWebAPI.shared
    @AppStorage(Prefs.spotifyClientID) private var clientID = ""
    @AppStorage(Prefs.autoLockMinutes) private var autoLockMinutes = 0
    @AppStorage(Prefs.lockOnScreenSleep) private var lockOnScreenSleep = false
    @AppStorage(Prefs.wallpaperMode) private var wallpaperMode = true
    @AppStorage(Prefs.lockScreenBar) private var lockScreenBar = true
    @AppStorage(Prefs.coverSize) private var coverSize = 0.38
    @AppStorage(Prefs.coverCenter) private var coverCenter = 0.44
    @AppStorage(Prefs.backgroundBlur) private var backgroundBlur = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowPlaying

            accessBanner

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("macOS Lock Screen")
                Toggle("Artwork on the lock screen", isOn: $wallpaperMode)
                Toggle("Liquid Glass bar on the lock screen", isOn: $lockScreenBar)
                if wallpaperMode {
                    Text("Your wallpaper is never changed while you use your Mac. Lock with ⌃⌘Q to see the result.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    labeledSlider("Size", value: $coverSize, range: 0.25...0.45)
                    labeledSlider("Position", value: $coverCenter, range: 0.36...0.52)
                    labeledSlider("Blur", value: $backgroundBlur, range: 0...1)
                }
            }
            .font(.system(size: 12))

            Divider()

            spotifyAccount

            Divider()

            sectionTitle("Tide Screen")

            Button {
                LockScreenManager.shared.lock()
            } label: {
                HStack {
                    Image(systemName: "lock.fill")
                    Text("Lock Now")
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
                Picker("Auto-lock", selection: $autoLockMinutes) {
                    Text("Never").tag(0)
                    Text("1 min").tag(1)
                    Text("2 min").tag(2)
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("15 min").tag(15)
                }
                Toggle("Lock when the display turns off", isOn: $lockOnScreenSleep)
            }
            .font(.system(size: 12))

            Divider()

            Button("Quit Tide") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private var spotifyAccount: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Spotify Account (♥ button)")
            if webAPI.isConnected {
                HStack {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") { webAPI.disconnect() }
                }
                .font(.system(size: 12))
            } else {
                Text("To have the ♥ filled when a track is already liked:\n1. developer.spotify.com/dashboard → Create app\n2. Redirect URI: \(SpotifyWebAPI.redirectURI)\n3. Check \"Web API\", save, and paste the Client ID here:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                HStack {
                    Button(webAPI.isConnecting ? "Connecting…" : "Connect to Spotify") { webAPI.connect() }
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Button("Open the dashboard") {
                        NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
                    }
                    .buttonStyle(.link)
                }
                .font(.system(size: 12))
                if !spotify.canLike {
                    Button("Or: ♥ without an account (Accessibility permission)") {
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
                        ? "Tide isn't allowed to control Spotify."
                        : "Tide needs access to Spotify.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)

                if spotify.access == .denied {
                    Text("System Settings › Privacy & Security › Automation › Tide → check Spotify.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Settings") { spotify.openAutomationSettings() }
                } else {
                    Button("Allow Access to Spotify") { spotify.requestAccess() }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: 10)
        } else if let error = spotify.lastError, spotify.track == nil {
            Text("Spotify: \(error)")
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
                Text(spotify.track?.title ?? (spotify.isRunning ? "Nothing Playing" : "Spotify isn't open"))
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
