import SwiftUI

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
            Prefs.instantBackground: true,
            Prefs.lockBackgroundSpaceLevel: Int(SkyLight.SpaceLevel.screenLock),
            // Sur l'écran verrouillé, loginwindow a un cache plein écran au niveau 2001 et son
            // interface (horloge, mot de passe) au niveau 2004 : le fond Tide se glisse entre les deux.
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
    /// Fond de l'écran verrouillé dessiné par Tide (instantané) en plus du fond d'écran.
    static let instantBackground = "instantBackground"
    /// Niveau de l'espace SkyLight du fond (écran verrouillé = 300). Expérimental.
    static let lockBackgroundSpaceLevel = "lockBackgroundSpaceLevel"
    /// Niveau de la fenêtre du fond dans cet espace. Expérimental.
    static let lockBackgroundWindowLevel = "lockBackgroundWindowLevel"
}
