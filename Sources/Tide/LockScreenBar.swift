import AppKit
import SwiftUI

/// Panel configured like boring.notch's so it can live above the lock screen.
private final class LockBarPanel: NSPanel {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canBecomeVisibleWithoutLogin = true
        acceptsMouseMovedEvents = true // hovering over the progress bar
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that responds to the very first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Liquid Glass bar (title, progress, ⏮ ⏯ ⏭) shown on the REAL lock screen,
/// just below the artwork drawn into the wallpaper.
@MainActor
final class LockScreenBar {
    static let shared = LockScreenBar()

    private var panel: LockBarPanel?
    private var isLocked = false
    /// SkyLight space the bar was placed in.
    private var space: Int32?
    private var unlockTask: Task<Void, Never>?

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked() }
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenUnlocked() }
        }
    }

    private func screenLocked() {
        isLocked = true
        SpotifyController.shared.refreshLikedState()
        unlockTask?.cancel()
        guard UserDefaults.standard.bool(forKey: Prefs.lockScreenBar),
              SkyLight.isAvailable,
              let screen = NSScreen.screens.first else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel, on: screen)
        panel.orderFrontRegardless()

        if space == nil {
            space = SkyLight.delegate(panel)
        }
    }

    private func screenUnlocked() {
        isLocked = false
        AudioOutputs.shared.isPickerVisible = false
        SpotifyController.shared.hoverProgress = nil
        // Short delay to avoid flickering during the unlock animation.
        unlockTask?.cancel()
        unlockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, !self.isLocked, let panel = self.panel else { return }
            if let space = self.space {
                SkyLight.undelegate(panel, from: space)
                self.space = nil
            }
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> LockBarPanel {
        LockBarPanel(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
    }

    /// Positions the bar relative to the artwork card (same Size/Position settings).
    private func layout(_ panel: LockBarPanel, on screen: NSScreen) {
        let defaults = UserDefaults.standard
        let frame = screen.frame
        let card = WallpaperRenderer.Layout(
            coverSize: defaults.double(forKey: Prefs.coverSize),
            coverCenter: defaults.double(forKey: Prefs.coverCenter)
        ).cardRect(screenWidth: frame.width, screenHeight: frame.height)

        // Same width as the artwork (both edges are aligned), just below it
        // with a small gap: it never overlaps it. All content is drawn
        // on a 300 × 124 grid of `s` units, to keep the same proportions
        // whatever the artwork size.
        let barWidth = max(card.width, 240)
        let s = barWidth / 300
        let barHeight = 124 * s
        // Same rounded corners as the artwork (radius = 4% of its width).
        let cornerRadius = card.width * 0.04
        let barTop = card.maxY + frame.height * 0.016 // from the top

        // The panel also holds the sharp artwork (above the bar): it changes
        // instantly, without waiting for macOS to apply the new wallpaper.
        // The margins leave room for its shadow.
        let margin = max(30, card.width * 0.14)
        // On the sides, enough room for the audio output pop-up, centered on
        // the 💻 button at the edge of the bar (half of it overflows, shadow included).
        let sideMargin = max(margin, OutputPopover.width(s: s) / 2 + 24 * s)
        let gap = barTop - card.maxY
        let coverSpace = card.height + gap
        let size = CGSize(width: max(barWidth, card.width) + sideMargin * 2,
                          height: card.height + gap + barHeight + margin * 2)
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - barTop - barHeight - margin
        )

        let hosting = FirstClickHostingView(
            rootView: LockBarContent(width: barWidth, height: barHeight, s: s, margin: margin,
                                     coverSide: card.width, coverSpace: coverSpace,
                                     cornerRadius: cornerRadius)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Bar content, only when a track is loaded.
private struct LockBarContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    let width: CGFloat
    let height: CGFloat
    let s: CGFloat
    let margin: CGFloat
    let coverSide: CGFloat
    /// Artwork height + gap down to the bar.
    let coverSpace: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            // Clicking outside the pop-up closes it, like on macOS.
            if outputs.isPickerVisible {
                Color.black.opacity(0.001)
                    .onTapGesture { outputs.isPickerVisible = false }
            } else {
                Color.clear
            }
            LockCover(side: coverSide, cornerRadius: cornerRadius)
                .padding(.top, margin)

            if let track = spotify.track {
                CompactPlayer(track: track, s: s)
                    .frame(width: width, height: height)
                    .liquidGlass(cornerRadius: cornerRadius, darkness: 0.28)
                    .overlayPreferenceValue(OutputButtonAnchorKey.self) { anchor in
                        GeometryReader { proxy in
                            if outputs.isPickerVisible, let anchor {
                                popover(button: proxy[anchor])
                            }
                        }
                    }
                    .padding(.top, margin + coverSpace)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: spotify.track?.id)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: outputs.isPickerVisible)
    }

    /// Pop-up centered above the 💻 button, with its arrow in the middle pointing at the icon.
    private func popover(button: CGRect) -> some View {
        let size = OutputPopover.size(s: s, rows: OutputPopover.visibleRows(outputs.devices.count))
        let gap = 4 * s
        let tipY = button.minY - gap

        return OutputPopover(s: s, arrowX: size.width / 2)
            .frame(width: size.width, height: size.height)
            .transition(
                .scale(scale: 0.5, anchor: .bottom)
                    .combined(with: .opacity)
            )
            .position(x: button.midX, y: tipY - size.height / 2)
    }
}

/// Sharp artwork, drawn by Tide above the wallpaper: it follows the track
/// immediately (cross-fade), whereas the wallpaper takes a moment to be applied.
private struct LockCover: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @AppStorage(Prefs.wallpaperMode) private var wallpaperMode = true
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if wallpaperMode, let art = spotify.artwork {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: max(1, side * 0.0025)))
                    .id(ObjectIdentifier(art))
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.5), radius: side * 0.07, y: side * 0.045)
        .animation(.easeOut(duration: LockTiming.artworkFade), value: spotify.artwork.map(ObjectIdentifier.init))
        .allowsHitTesting(false)
    }
}

/// Position of the 💻 button in the bar, to anchor the pop-up to it.
private struct OutputButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Rounded bubble with a small arrow at the bottom, like macOS popovers.
private struct PopoverShape: Shape {
    var cornerRadius: CGFloat
    /// X position of the tip, from the left edge.
    var arrowX: CGFloat
    var arrowWidth: CGFloat
    var arrowHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - arrowHeight)
        let r = min(cornerRadius, body.height / 2, body.width / 2)
        let ax = rect.minX + arrowX
        let half = arrowWidth / 2
        let tip = CGPoint(x: ax, y: rect.maxY)

        var p = Path()
        p.move(to: CGPoint(x: body.minX + r, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                 tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                 tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        // Arrow: softened sides and a rounded tip
        p.addLine(to: CGPoint(x: ax + half, y: body.maxY))
        p.addCurve(to: CGPoint(x: ax + half * 0.22, y: tip.y - arrowHeight * 0.12),
                   control1: CGPoint(x: ax + half * 0.55, y: body.maxY),
                   control2: CGPoint(x: ax + half * 0.4, y: tip.y - arrowHeight * 0.3))
        p.addQuadCurve(to: CGPoint(x: ax - half * 0.22, y: tip.y - arrowHeight * 0.12), control: tip)
        p.addCurve(to: CGPoint(x: ax - half, y: body.maxY),
                   control1: CGPoint(x: ax - half * 0.4, y: tip.y - arrowHeight * 0.3),
                   control2: CGPoint(x: ax - half * 0.55, y: body.maxY))
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                 tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                 tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// "3:07" from a number of seconds.
private func formatTime(_ t: TimeInterval) -> String {
    let total = max(Int(t.rounded(.down)), 0)
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Small time bubble when hovering the progress bar, Apple-style.
private struct TimeBubble: View {
    let text: String
    let s: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: 9 * s, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6 * s)
            .padding(.vertical, 2.5 * s)
            .fixedSize()
            .liquidGlass(Capsule(), darkness: 0.4)
            .shadow(color: .black.opacity(0.25), radius: 4 * s, y: 2 * s)
            .allowsHitTesting(false)
    }
}

/// Audio output picker pop-up, Control Center style:
/// floating Liquid Glass card, icons in pills, active output in blue.
private struct OutputPopover: View {
    @ObservedObject private var outputs = AudioOutputs.shared
    let s: CGFloat
    /// X position of the arrow tip, from the pop-up's left edge.
    var arrowX: CGFloat

    static let maxVisibleRows = 5
    static func rowHeight(s: CGFloat) -> CGFloat { 30 * s }
    static func width(s: CGFloat) -> CGFloat { 196 * s }
    static func arrowHeight(s: CGFloat) -> CGFloat { 7 * s }
    static func arrowWidth(s: CGFloat) -> CGFloat { 18 * s }
    static func cornerRadius(s: CGFloat) -> CGFloat { 14 * s }
    private static func headerHeight(s: CGFloat) -> CGFloat { 24 * s }
    private static func verticalPadding(s: CGFloat) -> CGFloat { 14 * s } // 5 at the top, 9 at the bottom

    static func visibleRows(_ count: Int) -> Int { max(min(count, maxVisibleRows), 1) }

    /// Total size, arrow included.
    static func size(s: CGFloat, rows: Int) -> CGSize {
        CGSize(width: width(s: s),
               height: headerHeight(s: s) + CGFloat(rows) * rowHeight(s: s)
                   + verticalPadding(s: s) + arrowHeight(s: s))
    }

    /// Maximum height, to reserve room in the panel.
    static func maxHeight(s: CGFloat) -> CGFloat { size(s: s, rows: maxVisibleRows).height }

    var body: some View {
        let rows = Self.visibleRows(outputs.devices.count)
        let shape = PopoverShape(cornerRadius: Self.cornerRadius(s: s), arrowX: arrowX,
                                 arrowWidth: Self.arrowWidth(s: s), arrowHeight: Self.arrowHeight(s: s))

        VStack(alignment: .leading, spacing: 0) {
            Text("Audio Output")
                .font(.system(size: 11 * s, weight: .bold))
                .padding(.horizontal, 8 * s)
                .frame(height: Self.headerHeight(s: s), alignment: .center)

            if outputs.devices.isEmpty {
                Text("No outputs available")
                    .font(.system(size: 10.5 * s, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 8 * s)
                    .frame(height: Self.rowHeight(s: s))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(outputs.devices) { device in
                            row(device)
                        }
                    }
                }
                .frame(height: CGFloat(rows) * Self.rowHeight(s: s))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6 * s)
        .padding(.top, 5 * s)
        .padding(.bottom, 9 * s + Self.arrowHeight(s: s))
        .frame(width: Self.width(s: s), alignment: .topLeading)
        .liquidGlass(shape, darkness: 0.38)
        .shadow(color: .black.opacity(0.3), radius: 18 * s, y: 8 * s)
    }

    private func row(_ device: AudioOutput) -> some View {
        let selected = device.id == outputs.currentID
        return Button { outputs.select(device) } label: {
            HStack(spacing: 9 * s) {
                ZStack {
                    Circle().fill(selected ? Color.accentColor : .white.opacity(0.14))
                    Image(systemName: device.symbol)
                        .font(.system(size: 10.5 * s, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22 * s, height: 22 * s)
                Text(device.name)
                    .font(.system(size: 11 * s, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5 * s)
            .frame(height: Self.rowHeight(s: s) - 2 * s)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(highlight: .rounded(8 * s), dims: false))
        .frame(height: Self.rowHeight(s: s))
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}

/// Compact player: title/artist, progress with times, then ⏮ ⏯ ⏭.
private struct CompactPlayer: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    let track: Track
    let s: CGFloat

    var body: some View {
        // 300 × 124 grid: margins 18 / 13, title (≈ 31), 9, progress (14),
        // flexible space, controls (≈ 36). The edges of the ♥ and 💻 line up with
        // those of the progress bar.
        VStack(spacing: 0) {
            // Title + artist, centered; small wave on the right
            ZStack {
                VStack(spacing: 2 * s) {
                    Text(track.title)
                        .font(.system(size: 12.5 * s, weight: .semibold))
                    Text(track.artist)
                        .font(.system(size: 11 * s, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)
                .padding(.horizontal, 24 * s)

                HStack {
                    Spacer()
                    EqualizerIcon(isPlaying: spotify.isPlaying, height: 10 * s)
                        .opacity(0.8)
                }
            }

            Spacer(minLength: 0).frame(height: 9 * s)

            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                progress(current: spotify.scrubPosition ?? spotify.position(at: ctx.date))
            }

            Spacer(minLength: 0)

            // ♥   ⏮ ⏯ ⏭   💻
            HStack(spacing: 0) {
                button(spotify.isCurrentTrackLiked ? "heart.fill" : "heart", size: 13 * s, edge: .leading) {
                    spotify.toggleLike()
                }
                Spacer(minLength: 0)
                HStack(spacing: 24 * s) {
                    button("backward.fill", size: 16 * s) { spotify.previous() }
                    button(spotify.isPlaying ? "pause.fill" : "play.fill", size: 23 * s) { spotify.playPause() }
                    button("forward.fill", size: 16 * s) { spotify.next() }
                }
                Spacer(minLength: 0)
                button(outputs.current?.symbol ?? "laptopcomputer", size: 13 * s, edge: .trailing,
                       active: outputs.isPickerVisible, reportsAnchor: true) {
                    if !outputs.isPickerVisible { outputs.refresh() }
                    outputs.isPickerVisible.toggle()
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18 * s)
        .padding(.vertical, 13 * s)
    }

    /// `edge`: the side buttons overflow slightly into the margin, so that the icon
    /// (not its hit area) lines up with the edge of the progress bar.
    private func button(_ symbol: String, size: CGFloat, edge: HorizontalEdge? = nil,
                        active: Bool = false, reportsAnchor: Bool = false,
                        action: @escaping () -> Void) -> some View {
        let side = size * 1.65
        let inset = (side - size) / 2
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: side, height: side)
                .background(Circle().fill(.white.opacity(active ? 0.22 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(highlight: .circle))
        .anchorPreference(key: OutputButtonAnchorKey.self, value: .bounds) { reportsAnchor ? $0 : nil }
        .padding(edge == .leading ? .leading : .trailing, edge == nil ? 0 : -inset)
        .animation(.easeOut(duration: 0.16), value: active)
    }

    private func progress(current: TimeInterval) -> some View {
        let duration = max(track.duration, 0.001)
        let fraction = min(max(current / duration, 0), 1)
        let scrubbing = spotify.scrubPosition != nil
        let hover = spotify.hoverProgress
        let active = scrubbing || hover != nil
        // Bubble: hovered position, or current position while dragging.
        let bubble: Double? = scrubbing ? fraction : hover

        return HStack(spacing: 8 * s) {
            Text(formatTime(current))
            GeometryReader { g in
                let width = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    // Subtle preview up to the hovered point
                    if let hover, !scrubbing, hover > fraction {
                        Capsule().fill(.white.opacity(0.16))
                            .frame(width: width * hover)
                    }
                    Capsule().fill(.white.opacity(active ? 1 : 0.88))
                        .frame(width: width * fraction)
                }
                .frame(height: (active ? 7 : 4) * s)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if let bubble {
                        TimeBubble(text: formatTime(bubble * duration), s: s)
                            .position(x: Self.clampBubble(bubble * width, width: width, s: s), y: -9 * s)
                            .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottom)))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        spotify.hoverProgress = min(max(location.x / width, 0), 1)
                    case .ended:
                        spotify.hoverProgress = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            spotify.scrubPosition = min(max(value.location.x / width, 0), 1) * duration
                        }
                        .onEnded { value in
                            spotify.seek(to: min(max(value.location.x / width, 0), 1) * duration)
                            spotify.scrubPosition = nil
                        }
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active)
                .animation(.easeOut(duration: 0.15), value: bubble == nil)
            }
            .frame(height: 14 * s)
            Text("-" + formatTime(track.duration - current))
        }
        .font(.system(size: 9.5 * s, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.65))
    }

    /// Keeps the bubble fully above the bar (no overflow at the ends).
    private static func clampBubble(_ x: CGFloat, width: CGFloat, s: CGFloat) -> CGFloat {
        let half = 15 * s
        guard width > half * 2 else { return width / 2 }
        return min(max(x, half), width - half)
    }
}
