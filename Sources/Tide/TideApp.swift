import SwiftUI

@main
struct TideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        WallpaperManager.shared.restoreOriginal()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            Prefs.wallpaperMode: true,
            Prefs.lockScreenBar: true,
            Prefs.coverSize: 0.38,
            Prefs.coverCenter: 0.44,
            Prefs.backgroundBlur: 0.0,
            // Disabled: loginwindow draws the lock screen background in the same window
            // as the clock (level 2004); below it, the Tide background is hidden, and above it
            // it would hide the clock and password.
            Prefs.instantBackground: false,
            Prefs.lockBackgroundSpaceLevel: Int(SkyLight.SpaceLevel.screenLock),
            // On the lock screen, loginwindow has a full-screen cover at level 2001 and its
            // UI (clock, password) at level 2004: the Tide background slots in between.
            Prefs.lockBackgroundWindowLevel: 2002,
        ])
        NSApp.setActivationPolicy(.accessory)

        SpotifyController.shared.start()
        WallpaperManager.shared.start()
        LockBackground.shared.start()
        LockScreenBar.shared.start()
    }
}

enum Prefs {
    static let wallpaperMode = "wallpaperMode"
    static let lockScreenBar = "lockScreenBar"
    static let backgroundBlur = "backgroundBlur"
    static let spotifyClientID = "spotifyClientID"
    static let coverSize = "squareCoverSize"
    static let coverCenter = "squareCoverCenter"
    /// Lock screen background drawn by Tide (instant), on top of the wallpaper.
    static let instantBackground = "instantBackground"
    /// SkyLight space level of the background (lock screen = 300). Experimental.
    static let lockBackgroundSpaceLevel = "lockBackgroundSpaceLevel"
    /// Window level of the background within that space. Experimental.
    static let lockBackgroundWindowLevel = "lockBackgroundWindowLevel"
}
