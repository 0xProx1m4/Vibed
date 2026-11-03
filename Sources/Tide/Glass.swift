import SwiftUI

extension View {
    /// Effet « Liquid Glass ». Utilise le vrai matériau de macOS 26 quand il est disponible,
    /// sinon une imitation (matériau flouté + reflets sur les bords).
    @ViewBuilder
    func liquidGlass<S: Shape>(_ shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.modifier(FallbackGlass(shape: shape))
        }
        #else
        self.modifier(FallbackGlass(shape: shape))
        #endif
    }

    func liquidGlass(cornerRadius: CGFloat) -> some View {
        liquidGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct FallbackGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content
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

/// Bouton qui se « tasse » quand on appuie, comme sur iOS.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
