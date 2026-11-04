import AppKit

/// Logo de Tide : un disque fin contenant une vague. Dessiné en vectoriel
/// (même tracé que `Resources/TideLogo.svg`) et rendu en image « template »
/// pour que macOS l'adapte tout seul au thème clair/sombre de la barre des menus.
enum TideLogo {
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()

            let ring = NSBezierPath(ovalIn: NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5))
            ring.lineWidth = 1.5
            ring.stroke()

            let wave = NSBezierPath()
            wave.lineWidth = 1.5
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.move(to: NSPoint(x: 4.6, y: 9.6))
            wave.curve(to: NSPoint(x: 9, y: 9.6),
                       controlPoint1: NSPoint(x: 6, y: 7.1), controlPoint2: NSPoint(x: 7.6, y: 7.1))
            wave.curve(to: NSPoint(x: 13.4, y: 9.6),
                       controlPoint1: NSPoint(x: 10.4, y: 12.1), controlPoint2: NSPoint(x: 12, y: 12.1))
            wave.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tide"
        return image
    }()
}
