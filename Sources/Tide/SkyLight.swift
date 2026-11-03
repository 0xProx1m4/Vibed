import AppKit
import Darwin

/// Accès (privé) au serveur de fenêtres de macOS pour afficher une fenêtre
/// au-dessus du vrai écran de verrouillage. Chargé dynamiquement : si une version
/// de macOS change ces fonctions, `moveAboveLockScreen` renvoie simplement false.
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsToSpace = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private struct API {
        let connection: Int32
        let space: Int32
        let addWindows: AddWindowsToSpace
    }

    /// Espace créé une seule fois, placé au-dessus de l'écran de verrouillage.
    private static let api: API? = {
        guard let mainConnection = load("SLSMainConnectionID", as: MainConnectionID.self),
              let spaceCreate = load("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let showSpaces = load("SLSShowSpaces", as: ShowSpaces.self),
              let addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsToSpace.self)
        else {
            NSLog("Tide – SkyLight indisponible, la barre ne peut pas s'afficher sur l'écran verrouillé")
            return nil
        }
        let connection = mainConnection()
        let space = spaceCreate(connection, 1, 0)
        _ = setLevel(connection, space, 100)
        _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)
        return API(connection: connection, space: space, addWindows: addWindows)
    }()

    static var isAvailable: Bool { api != nil }

    /// Déplace la fenêtre (déjà affichée) dans l'espace au-dessus de l'écran de verrouillage.
    @discardableResult
    static func moveAboveLockScreen(_ window: NSWindow) -> Bool {
        guard let api, window.windowNumber > 0 else { return false }
        _ = api.addWindows(api.connection, api.space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return true
    }
}
