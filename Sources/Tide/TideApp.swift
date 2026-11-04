import SwiftUI
import Carbon.HIToolbox

@main
struct TideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Tide", systemImage: "water.waves") {
            MenuContent()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKey: HotKey?
    private var idleTimer: Timer?

    func applicationWillTerminate(_ notification: Notification) {
        WallpaperManager.shared.restoreOriginal()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Prefs.autoLockMinutes: 0,
            Prefs.lockOnScreenSleep: false,
            Prefs.wallpaperMode: true,
            Prefs.lockScreenBar: true,
            Prefs.coverSize: 0.38,
            Prefs.coverCenter: 0.44,
            Prefs.backgroundBlur: 0.0,
        ])
        NSApp.setActivationPolicy(.accessory)

        SpotifyController.shared.start()
        WallpaperManager.shared.start()
        LockScreenBar.shared.start()

        // ⌃⌥⌘L  → lock
        hotKey = HotKey(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | optionKey | controlKey)
        ) {
            LockScreenManager.shared.lock()
        }

        // Auto-lock after inactivity
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            Task { @MainActor in
                let minutes = UserDefaults.standard.integer(forKey: Prefs.autoLockMinutes)
                guard minutes > 0, !LockScreenManager.shared.isLocked else { return }
                let anyInput = CGEventType(rawValue: ~0)!
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                if idle >= Double(minutes * 60) {
                    LockScreenManager.shared.lock()
                }
            }
        }

        // Lock when the display turns off, so it's there on wake
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                if UserDefaults.standard.bool(forKey: Prefs.lockOnScreenSleep) {
                    LockScreenManager.shared.lock()
                }
            }
        }
    }
}

enum Prefs {
    static let wallpaperMode = "wallpaperMode"
    static let lockScreenBar = "lockScreenBar"
    static let backgroundBlur = "backgroundBlur"
    static let spotifyClientID = "spotifyClientID"
    static let coverSize = "squareCoverSize"
    static let coverCenter = "squareCoverCenter"
    static let autoLockMinutes = "autoLockMinutes"
    static let lockOnScreenSleep = "lockOnScreenSleep"
}
