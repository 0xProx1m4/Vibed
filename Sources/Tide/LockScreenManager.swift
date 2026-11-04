import AppKit
import SwiftUI
import LocalAuthentication

/// Full-screen window that can receive keyboard input despite having no title bar.
final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows the Tide lock screen above everything, on every display,
/// and only removes it after Touch ID / the Mac password.
@MainActor
final class LockScreenManager: ObservableObject {
    static let shared = LockScreenManager()

    @Published private(set) var isLocked = false
    @Published private(set) var isAuthenticating = false

    private var windows: [LockWindow] = []
    private var previousOptions: NSApplication.PresentationOptions = []
    private var keyMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    private static let shieldLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    // MARK: - Lock

    func lock() {
        guard !isLocked else { return }
        isLocked = true

        NSApp.activate(ignoringOtherApps: true)
        previousOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [
            .hideDock, .hideMenuBar, .disableAppleMenu,
            .disableProcessSwitching, .disableForceQuit,
            .disableSessionTermination, .disableHideApplication,
        ]

        buildWindows(animated: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKey(event)
            return nil // swallow every key (⌘Q, ⌘W…)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLocked else { return }
                self.buildWindows(animated: false)
            }
        }
    }

    // MARK: - Unlock

    func requestUnlock() {
        guard isLocked, !isAuthenticating else { return }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Mac without a password: nothing to verify.
            unlock()
            return
        }

        isAuthenticating = true
        // Drop down a level so the Touch ID / password prompt can appear in front.
        windows.forEach { $0.level = .floating }

        Task { @MainActor in
            let success = (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "unlock the screen"
            )) ?? false

            self.isAuthenticating = false
            if success {
                self.unlock()
            } else {
                self.windows.forEach { $0.level = Self.shieldLevel }
                self.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func unlock() {
        guard isLocked else { return }
        isLocked = false

        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil

        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            Task { @MainActor in
                closing.forEach { $0.orderOut(nil) }
                NSApp.presentationOptions = self.previousOptions
            }
        })
    }

    // MARK: - Internal

    private func buildWindows(animated: Bool) {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = LockWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: false)
            window.level = Self.shieldLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: LockScreenView()
                    .environment(\.colorScheme, .dark)
            )
            window.alphaValue = animated ? 0 : 1
            window.orderFrontRegardless()
            return window
        }
        windows.first?.makeKeyAndOrderFront(nil)

        if animated {
            let opening = windows
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.5
                opening.forEach { $0.animator().alphaValue = 1 }
            }
        }
    }

    private func handleKey(_ event: NSEvent) {
        let spotify = SpotifyController.shared
        switch event.keyCode {
        case 49:  spotify.playPause()   // space
        case 123: spotify.previous()    // ←
        case 124: spotify.next()        // →
        default:  requestUnlock()
        }
    }
}
