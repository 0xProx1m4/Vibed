import AppKit
import Darwin

/// (Private) access to the macOS window server to show a window above the
/// real lock screen — same technique as boring.notch (via SkyLightWindow).
/// The functions are loaded dynamically: if macOS removes them, everything is simply disabled.
enum SkyLight {
    /// Absolute levels of the window server "spaces".
    /// The lock screen is at 300.
    enum SpaceLevel {
        static let screenLock: Int32 = 300
        static let notificationCenterAtScreenLock: Int32 = 400
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
        let spaceCreate: SpaceCreate
        let setLevel: SpaceSetAbsoluteLevel
        let showSpaces: ShowSpaces
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
            NSLog("Tide – SkyLight unavailable, nothing can be shown on the lock screen")
            return nil
        }
        return API(
            connection: mainConnection(),
            spaceCreate: spaceCreate,
            setLevel: setLevel,
            showSpaces: showSpaces,
            addWindows: addWindows,
            removeWindows: load("SLSRemoveWindowsFromSpaces", as: RemoveWindowsFromSpaces.self)
        )
    }()

    /// One space per level, created on first use.
    @MainActor private static var spaces: [Int32: Int32] = [:]

    static var isAvailable: Bool { api != nil }

    @MainActor private static func space(level: Int32) -> Int32? {
        guard let api else { return nil }
        if let space = spaces[level] { return space }
        let space = api.spaceCreate(api.connection, 1, 0)
        _ = api.setLevel(api.connection, space, level)
        _ = api.showSpaces(api.connection, [space] as CFArray)
        spaces[level] = space
        return space
    }

    /// Moves the (already visible) window into a space at the given level. Returns the space,
    /// to pass back to `undelegate`.
    @MainActor @discardableResult
    static func delegate(_ window: NSWindow, level: Int32 = SpaceLevel.notificationCenterAtScreenLock) -> Int32? {
        guard let api, window.windowNumber > 0, let space = space(level: level) else { return nil }
        _ = api.addWindows(api.connection, space, [window.windowNumber] as CFArray, 7)
        return space
    }

    /// Removes the window from that space.
    @MainActor static func undelegate(_ window: NSWindow, from space: Int32) {
        guard let api, let remove = api.removeWindows, window.windowNumber > 0 else { return }
        _ = remove(api.connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
