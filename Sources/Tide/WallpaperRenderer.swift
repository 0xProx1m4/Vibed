import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Génère l'image de fond : pochette agrandie et floutée + pochette nette au centre.
/// L'horloge et le lecteur sont ensuite dessinés par macOS sur le vrai écran de verrouillage.
enum WallpaperRenderer {
    struct Layout {
        /// Côté de la pochette, en fraction de la hauteur de l'écran.
        var coverSize: CGFloat
        /// Centre vertical de la pochette, en fraction de la hauteur (0 = haut, 1 = bas).
        var coverCenter: CGFloat
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func render(cover: CGImage, pixelSize: CGSize, layout: Layout) -> Data? {
        let width = pixelSize.width.rounded()
        let height = pixelSize.height.rounded()
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: Int(width), height: Int(height),
                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.interpolationQuality = .high

        // 1. Fond : pochette en « remplissage », légèrement zoomée et floutée
        let source = CIImage(cgImage: cover)
        let fill = max(width / source.extent.width, height / source.extent.height) * 1.12
        let background = source
            .transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            .transformed(by: CGAffineTransform(
                translationX: (width - source.extent.width * fill) / 2,
                y: (height - source.extent.height * fill) / 2
            ))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: height * 0.009)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.12,
                kCIInputBrightnessKey: -0.05,
            ])
            .cropped(to: canvas)

        if let bg = ciContext.createCGImage(background, from: canvas, format: .RGBA8, colorSpace: space) {
            ctx.draw(bg, in: canvas)
        }

        // 2. Vignette pour faire ressortir l'horloge et le lecteur
        let black = { (a: CGFloat) in CGColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }
        let center = CGPoint(x: width / 2, y: height / 2)
        if let vignette = CGGradient(colorsSpace: space, colors: [black(0), black(0.5)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(vignette, startCenter: center, startRadius: height * 0.3,
                                   endCenter: center, endRadius: max(width, height) * 0.75,
                                   options: [.drawsAfterEndLocation])
        }
        if let top = CGGradient(colorsSpace: space, colors: [black(0.3), black(0)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(top, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: height * 0.7), options: [])
        }

        // 3. Pochette nette, coins arrondis, ombre portée
        let side = height * layout.coverSize
        let centerY = height * (1 - layout.coverCenter) // CoreGraphics : origine en bas
        let rect = CGRect(x: (width - side) / 2, y: centerY - side / 2, width: side, height: side)
        let radius = side * 0.055
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.05), blur: side * 0.16, color: black(0.55))
        ctx.addPath(path)
        ctx.setFillColor(black(1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let scale = max(side / CGFloat(cover.width), side / CGFloat(cover.height))
        let drawW = CGFloat(cover.width) * scale
        let drawH = CGFloat(cover.height) * scale
        ctx.draw(cover, in: CGRect(x: rect.midX - drawW / 2, y: rect.midY - drawH / 2, width: drawW, height: drawH))
        ctx.restoreGState()

        // Liseré « verre »
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.setLineWidth(max(1, side * 0.0025))
        ctx.strokePath()

        guard let image = ctx.makeImage() else { return nil }

        // 4. Encodage JPEG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
