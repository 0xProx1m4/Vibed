import SwiftUI

extension View {
    /// "Liquid Glass" effect. Uses the real macOS 26 material when available,
    /// otherwise an imitation (blurred material + edge highlights).
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

/// Button that "squishes" when pressed, like on iOS.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
