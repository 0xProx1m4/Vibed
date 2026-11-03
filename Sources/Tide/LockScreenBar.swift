import AppKit
import SwiftUI

/// Panneau configuré comme celui de boring.notch pour pouvoir vivre au-dessus du verrouillage.
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
        acceptsMouseMovedEvents = true // survol de la barre de progression
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Vue hébergée qui réagit dès le premier clic.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Barre Liquid Glass (titre, durée, ⏮ ⏯ ⏭) affichée sur le VRAI écran de verrouillage,
/// juste sous la pochette dessinée dans le fond d'écran.
@MainActor
final class LockScreenBar {
    static let shared = LockScreenBar()

    private var panel: LockBarPanel?
    private var isLocked = false
    private var isDelegated = false
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

        if !isDelegated {
            SkyLight.delegate(panel)
            isDelegated = true
        }
    }

    private func screenUnlocked() {
        isLocked = false
        AudioOutputs.shared.isPickerVisible = false
        SpotifyController.shared.hoverProgress = nil
        // Petit délai pour éviter un clignotement pendant l'animation de déverrouillage.
        unlockTask?.cancel()
        unlockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled, !self.isLocked, let panel = self.panel else { return }
            if self.isDelegated {
                SkyLight.undelegate(panel)
                self.isDelegated = false
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

    /// Place la barre à cheval sur le bas de la carte pochette (mêmes réglages Taille/Position).
    private func layout(_ panel: LockBarPanel, on screen: NSScreen) {
        let defaults = UserDefaults.standard
        let frame = screen.frame
        let card = WallpaperRenderer.Layout(
            coverSize: defaults.double(forKey: Prefs.coverSize),
            coverCenter: defaults.double(forKey: Prefs.coverCenter)
        ).cardRect(screenWidth: frame.width, screenHeight: frame.height)

        // Même largeur que la pochette (les deux bords sont alignés), juste en dessous
        // avec un petit espace : elle ne la recouvre jamais. Tout le contenu est dessiné
        // sur une grille de 300 × 124 unités `s`, pour garder les mêmes proportions
        // quelle que soit la taille de la pochette.
        let barWidth = max(card.width, 240)
        let s = barWidth / 300
        let barHeight = 124 * s
        // Mêmes coins arrondis que la pochette (rayon = 4 % de sa largeur).
        let cornerRadius = card.width * 0.04
        let barTop = card.maxY + frame.height * 0.016 // depuis le haut

        let margin: CGFloat = 30 // place pour l'ombre
        let popoverSpace = OutputPopover.maxHeight(s: s) + 12 * s // pop-up des sorties audio, au-dessus
        let size = CGSize(width: barWidth + margin * 2, height: barHeight + margin * 2 + popoverSpace)
        let origin = CGPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - barTop - barHeight - margin
        )

        let hosting = FirstClickHostingView(
            rootView: LockBarContent(width: barWidth, height: barHeight, s: s, margin: margin,
                                     popoverSpace: popoverSpace, cornerRadius: cornerRadius)
                .environment(\.colorScheme, .dark)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

/// Contenu de la barre, uniquement si un morceau est chargé.
private struct LockBarContent: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    let width: CGFloat
    let height: CGFloat
    let s: CGFloat
    let margin: CGFloat
    let popoverSpace: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            // Un clic à côté du pop-up le referme, comme sur macOS.
            if outputs.isPickerVisible {
                Color.black.opacity(0.001)
                    .onTapGesture { outputs.isPickerVisible = false }
            } else {
                Color.clear
            }
            if let track = spotify.track {
                CompactPlayer(track: track, s: s)
                    .frame(width: width, height: height)
                    .liquidGlass(cornerRadius: cornerRadius, darkness: 0.28)
                    .overlayPreferenceValue(OutputButtonAnchorKey.self) { anchor in
                        GeometryReader { proxy in
                            if outputs.isPickerVisible, let anchor {
                                popover(button: proxy[anchor], barWidth: proxy.size.width)
                            }
                        }
                    }
                    .padding(.top, margin + popoverSpace)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: spotify.track?.id)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: outputs.isPickerVisible)
    }

    /// Pop-up posé juste au-dessus du bouton 💻, sa flèche pointant sur le bouton.
    /// Il s'aligne sur le bord droit de la barre tant que la flèche peut rester sous le bouton.
    private func popover(button: CGRect, barWidth: CGFloat) -> some View {
        let size = OutputPopover.size(s: s, rows: OutputPopover.visibleRows(outputs.devices.count))
        let gap = 4 * s
        let minX = min(max(button.midX - size.width / 2, 0), max(barWidth - size.width, 0))
        let tipY = button.minY - gap
        let arrowX = OutputPopover.clampArrow(button.midX - minX, width: size.width, s: s)

        return OutputPopover(s: s, arrowX: arrowX)
            .frame(width: size.width, height: size.height)
            .transition(
                .scale(scale: 0.5, anchor: UnitPoint(x: arrowX / size.width, y: 1))
                    .combined(with: .opacity)
            )
            .position(x: minX + size.width / 2, y: tipY - size.height / 2)
    }
}

/// Position du bouton 💻 dans la barre, pour y accrocher le pop-up.
private struct OutputButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Bulle à coins arrondis avec une petite flèche en bas, comme les popovers de macOS.
private struct PopoverShape: Shape {
    var cornerRadius: CGFloat
    /// Abscisse de la pointe, depuis le bord gauche.
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
        // Flèche : flancs adoucis et pointe arrondie
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

/// « 3:07 » à partir d'un nombre de secondes.
private func formatTime(_ t: TimeInterval) -> String {
    let total = max(Int(t.rounded(.down)), 0)
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Petite bulle de temps au survol de la barre de progression, façon Apple.
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

/// Pop-up de choix de la sortie audio, façon Centre de contrôle :
/// carte Liquid Glass flottante, icônes dans des pastilles, sortie active en bleu.
private struct OutputPopover: View {
    @ObservedObject private var outputs = AudioOutputs.shared
    let s: CGFloat
    /// Abscisse de la pointe de la flèche, depuis le bord gauche du pop-up.
    var arrowX: CGFloat

    static let maxVisibleRows = 5
    static func rowHeight(s: CGFloat) -> CGFloat { 30 * s }
    static func width(s: CGFloat) -> CGFloat { 196 * s }
    static func arrowHeight(s: CGFloat) -> CGFloat { 7 * s }
    static func arrowWidth(s: CGFloat) -> CGFloat { 18 * s }
    static func cornerRadius(s: CGFloat) -> CGFloat { 14 * s }
    private static func headerHeight(s: CGFloat) -> CGFloat { 24 * s }
    private static func verticalPadding(s: CGFloat) -> CGFloat { 14 * s } // 5 en haut, 9 en bas

    static func visibleRows(_ count: Int) -> Int { max(min(count, maxVisibleRows), 1) }

    /// Taille totale, flèche comprise.
    static func size(s: CGFloat, rows: Int) -> CGSize {
        CGSize(width: width(s: s),
               height: headerHeight(s: s) + CGFloat(rows) * rowHeight(s: s)
                   + verticalPadding(s: s) + arrowHeight(s: s))
    }

    /// Hauteur maximale, pour réserver la place dans le panneau.
    static func maxHeight(s: CGFloat) -> CGFloat { size(s: s, rows: maxVisibleRows).height }

    /// Garde la flèche sur la partie droite du bord, hors des coins arrondis.
    static func clampArrow(_ x: CGFloat, width: CGFloat, s: CGFloat) -> CGFloat {
        let margin = cornerRadius(s: s) + arrowWidth(s: s) / 2
        return min(max(x, margin), width - margin)
    }

    var body: some View {
        let rows = Self.visibleRows(outputs.devices.count)
        let shape = PopoverShape(cornerRadius: Self.cornerRadius(s: s), arrowX: arrowX,
                                 arrowWidth: Self.arrowWidth(s: s), arrowHeight: Self.arrowHeight(s: s))

        VStack(alignment: .leading, spacing: 0) {
            Text("Sortie audio")
                .font(.system(size: 11 * s, weight: .bold))
                .padding(.horizontal, 8 * s)
                .frame(height: Self.headerHeight(s: s), alignment: .center)

            if outputs.devices.isEmpty {
                Text("Aucune sortie disponible")
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

/// Lecteur compact : titre/artiste, progression avec temps, puis ⏮ ⏯ ⏭.
private struct CompactPlayer: View {
    @ObservedObject private var spotify = SpotifyController.shared
    @ObservedObject private var outputs = AudioOutputs.shared
    let track: Track
    let s: CGFloat

    var body: some View {
        // Grille 300 × 124 : marges 18 / 13, titre (≈ 31), 9, progression (14),
        // espace souple, commandes (≈ 36). Les bords du ♥ et du 💻 tombent sur ceux
        // de la barre de progression.
        VStack(spacing: 0) {
            // Titre + artiste, centrés ; petite onde à droite
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

    /// `edge` : les boutons des côtés débordent un peu dans la marge, pour que l'icône
    /// (et non sa zone cliquable) s'aligne sur le bord de la barre de progression.
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
        // Bulle : position survolée, ou position en cours pendant le glisser.
        let bubble: Double? = scrubbing ? fraction : hover

        return HStack(spacing: 8 * s) {
            Text(formatTime(current))
            GeometryReader { g in
                let width = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    // Aperçu discret jusqu'au point survolé
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

    /// Garde la bulle entièrement au-dessus de la barre (pas de débordement aux extrémités).
    private static func clampBubble(_ x: CGFloat, width: CGFloat, s: CGFloat) -> CGFloat {
        let half = 15 * s
        guard width > half * 2 else { return width / 2 }
        return min(max(x, half), width - half)
    }
}
