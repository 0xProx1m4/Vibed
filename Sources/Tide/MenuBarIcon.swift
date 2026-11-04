import AppKit

/// Tide's menu bar icon: rounded bars riding a sine wave — a sound wave shaped like a tide.
///
/// Drawn in code as a template image, so macOS tints it automatically for light and dark
/// menu bars (and when the menu is open), exactly like the system icons.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            // Designed on a 24-unit grid (like an SF Symbol), then scaled and centered.
            let scale: CGFloat = 0.8
            let transform = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -12, y: -12)

            let count = 9
            let barWidth: CGFloat = 1.7
            let barHeight: CGFloat = 6.4
            let amplitude: CGFloat = 3.6

            NSColor.black.setFill()
            for index in 0..<count {
                let t = CGFloat(index) / CGFloat(count - 1)
                let x = 3.2 + t * 17.6
                // One full wave period from left to right; the left side rises first.
                let centerY = 12 - sin(t * 2 * .pi) * amplitude
                let bar = CGRect(x: x - barWidth / 2, y: centerY - barHeight / 2,
                                 width: barWidth, height: barHeight).applying(transform)
                let radius = bar.width / 2
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tide"
        return image
    }()
}
