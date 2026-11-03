import SwiftUI

extension View {
    /// Effet « Liquid Glass ». Utilise le vrai matériau de macOS 26 quand il est disponible,
    /// sinon une imitation (matériau flouté + reflets sur les bords).
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S, darkness: Double = 0) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(
                darkness > 0 ? .regular.tint(.black.opacity(darkness)).interactive() : .regular.interactive(),
                in: shape
            )
        } else {
            self.modifier(FallbackGlass(shape: shape, darkness: darkness))
        }
        #else
        self.modifier(FallbackGlass(shape: shape, darkness: darkness))
        #endif
    }

    func liquidGlass(cornerRadius: CGFloat, darkness: Double = 0) -> some View {
        liquidGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), darkness: darkness)
    }
}

private struct FallbackGlass<S: Shape>: ViewModifier {
    let shape: S
    var darkness: Double = 0

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.black.opacity(darkness)))
            .background(.ultraThinMaterial, in: shape)
            .background(shape.fill(Color.white.opacity(0.05)))
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.06), .white.opacity(0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
    }
}

/// Forme du halo affiché derrière un bouton survolé.
enum HoverHighlight {
    /// Pas de halo : le bouton s'éclaircit légèrement.
    case none
    /// Pastille ronde derrière une icône (commandes de lecture).
    case circle
    /// Fond arrondi derrière une ligne (listes).
    case rounded(CGFloat)
}

/// Bouton qui réagit au survol (halo doux, icône plus nette, léger grossissement)
/// et se « tasse » quand on appuie, comme sur iOS.
struct PressableStyle: ButtonStyle {
    var highlight: HoverHighlight = .none
    /// Atténue légèrement le contenu au repos (icônes seules).
    var dims = true

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, highlight: highlight, dims: dims)
    }
}

private struct PressableBody: View {
    let configuration: ButtonStyleConfiguration
    let highlight: HoverHighlight
    let dims: Bool
    // `State` déclaré sans `@` : avec le SDK macOS 27, `@State` est une macro dont le
    // plugin n'existe que dans Xcode, pas dans les Command Line Tools.
    private let hoverState = State(initialValue: false)
    private var isHovered: Bool {
        get { hoverState.wrappedValue }
        nonmutating set { hoverState.wrappedValue = newValue }
    }
    @Environment(\.isEnabled) private var isEnabled

    private var hovered: Bool { isHovered && isEnabled }
    private var pressed: Bool { configuration.isPressed }

    private var fillOpacity: Double {
        pressed ? 0.24 : (hovered ? 0.14 : 0)
    }

    private var scale: CGFloat {
        if pressed { return 0.88 }
        if case .circle = highlight, hovered { return 1.08 }
        return 1
    }

    var body: some View {
        configuration.label
            .opacity(labelOpacity)
            .brightness(highlightIsNone && hovered ? 0.06 : 0)
            .background { halo }
            .scaleEffect(scale)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: hovered)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
    }

    private var highlightIsNone: Bool {
        if case .none = highlight { return true }
        return false
    }

    /// Les icônes sont un peu atténuées au repos et deviennent pleinement blanches au survol.
    private var labelOpacity: Double {
        guard dims, !highlightIsNone else { return 1 }
        return hovered || pressed ? 1 : 0.86
    }

    @ViewBuilder
    private var halo: some View {
        switch highlight {
        case .none:
            EmptyView()
        case .circle:
            Circle()
                .fill(.white.opacity(fillOpacity))
                .scaleEffect(hovered || pressed ? 1 : 0.7)
        case .rounded(let radius):
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.white.opacity(fillOpacity))
        }
    }
}
