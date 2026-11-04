import AppKit
import Darwin

/// (Private) access to the macOS window server to show a window above the
/// real lock screen — same technique as boring.notch (via SkyLightWindow).
/// The functions are loaded dynamically: if macOS removes them, everything is simply disabled.
enum SkyLight {
    /// Absolute levels of the window server "spaces".
    /// The lock screen is at 300: we need to be above it.
    private enum SpaceLevel: Int32 {
        case screenLock = 300
        case notificationCenterAtScreenLock = 400
    }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsToSpace = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private struct API {
        let connection: Int32
        let space: Int32
        let addWindows: AddWindowsToSpace
        let removeWindows: RemoveWindowsFromSpaces?
    }

    private static let api: API? = {
        guard let mainConnection = load("SLSMainConnectionID", as: MainConnectionID.self),
              let spaceCreate = load("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let showSpaces = load("SLSShowSpaces", as: ShowSpaces.self),
              let addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindowsToSpace.self)
        else {
            NSLog("Tide – SkyLight unavailable, the bar cannot be shown on the lock screen")
            return nil
        }
        let connection = mainConnection()
        let space = spaceCreate(connection, 1, 0)
        _ = setLevel(connection, space, SpaceLevel.notificationCenterAtScreenLock.rawValue)
        _ = showSpaces(connection, [space] as CFArray)
        return API(
            connection: connection,
            space: space,
            addWindows: addWindows,
            removeWindows: load("SLSRemoveWindowsFromSpaces", as: RemoveWindowsFromSpaces.self)
        )
    }()

    static var isAvailable: Bool { api != nil }

    /// Moves the (already visible) window into the space above the lock screen.
    static func delegate(_ window: NSWindow) {
        guard let api, window.windowNumber > 0 else { return }
        _ = api.addWindows(api.connection, api.space, [window.windowNumber] as CFArray, 7)
    }

    /// Removes the window from that space.
    static func undelegate(_ window: NSWindow) {
        guard let api, let remove = api.removeWindows, window.windowNumber > 0 else { return }
        _ = remove(api.connection, [window.windowNumber] as CFArray, [api.space] as CFArray)
    }
}
