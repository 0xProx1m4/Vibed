import SwiftUI

/// Petit égaliseur animé (style Apple Music) : des barres arrondies qui ondulent
/// de façon organique pendant la lecture et se posent en douceur à la pause.
struct EqualizerIcon: View {
    let isPlaying: Bool
    /// Hauteur totale de l'icône.
    var height: CGFloat = 9

    private static let speeds: [Double] = [5.1, 7.3, 6.2, 8.4, 5.7]
    private static let phases: [Double] = [0.0, 1.3, 2.6, 0.7, 1.9]
    /// Hauteurs au repos (pause) : petite silhouette d'onde.
    private static let resting: [Double] = [0.3, 0.5, 0.7, 0.45, 0.3]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: height * 0.14) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .frame(
                            width: height * 0.17,
                            height: max(height * 0.17, height * level(index, at: t))
                        )
                }
            }
            .frame(height: height)
        }
        .opacity(isPlaying ? 0.85 : 0.4)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isPlaying)
        .accessibilityLabel(isPlaying ? "En lecture" : "En pause")
    }

    private func level(_ index: Int, at t: Double) -> Double {
        guard isPlaying else { return Self.resting[index] }
        // Deux sinusoïdes décalées : mouvement vivant mais jamais saccadé.
        let speed = Self.speeds[index]
        let phase = Self.phases[index]
        let a = sin(t * speed + phase)
        let b = sin(t * speed * 1.63 + phase * 2.1)
        return 0.22 + 0.78 * (0.5 + 0.28 * a + 0.22 * b)
    }
}
