import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Génère l'image de fond : pochette agrandie et floutée + pochette nette au centre.
/// L'horloge et le lecteur sont ensuite dessinés par macOS sur le vrai écran de verrouillage.
enum WallpaperRenderer {
    struct Layout {
        /// Hauteur de la carte pochette, en fraction de la hauteur de l'écran.
        var coverSize: CGFloat
        /// Centre vertical de la carte, en fraction de la hauteur (0 = haut, 1 = bas).
        var coverCenter: CGFloat
        /// Flou du fond, de 0 (net, comme la référence) à 1.
        var blur: CGFloat = 0

        /// Carte en portrait, comme sur l'écran de verrouillage de référence.
        static let aspectRatio: CGFloat = 0.8

        /// Rectangle de la carte, en coordonnées « depuis le haut » (pour une hauteur d'écran donnée).
        func cardRect(screenWidth: CGFloat, screenHeight: CGFloat) -> CGRect {
            let h = screenHeight * coverSize
            let w = h * Self.aspectRatio
            return CGRect(x: (screenWidth - w) / 2, y: screenHeight * coverCenter - h / 2, width: w, height: h)
        }
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func render(cover: CGImage, pixelSize: CGSize, layout: Layout, drawsCard: Bool = true) -> Data? {
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

        // 1. Fond : pochette en « remplissage », légèrement zoomée, nette par défaut.
        //    Agrandissement Lanczos (bien plus net qu'un simple redimensionnement).
        let source = CIImage(cgImage: cover)
        let fill = max(width / source.extent.width, height / source.extent.height) * 1.12
        let scaled = source.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: fill,
            kCIInputAspectRatioKey: 1.0,
        ])
        var background = scaled
            .transformed(by: CGAffineTransform(
                translationX: (width - scaled.extent.width) / 2 - scaled.extent.minX,
                y: (height - scaled.extent.height) / 2 - scaled.extent.minY
            ))
            .clampedToExtent()
        if layout.blur > 0 {
            background = background.applyingGaussianBlur(sigma: height * 0.012 * layout.blur)
        }
        background = background
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.08,
                kCIInputBrightnessKey: -0.02,
            ])
            .cropped(to: canvas)

        if let bg = ciContext.createCGImage(background, from: canvas, format: .RGBA8, colorSpace: space) {
            ctx.draw(bg, in: canvas)
        }

        // 2. Vignette pour faire ressortir l'horloge et le lecteur
        let black = { (a: CGFloat) in CGColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }
        let center = CGPoint(x: width / 2, y: height / 2)
        if let vignette = CGGradient(colorsSpace: space, colors: [black(0), black(0.3)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(vignette, startCenter: center, startRadius: height * 0.3,
                                   endCenter: center, endRadius: max(width, height) * 0.75,
                                   options: [.drawsAfterEndLocation])
        }
        if let top = CGGradient(colorsSpace: space, colors: [black(0.2), black(0)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(top, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: height * 0.7), options: [])
        }

        if drawsCard {
            // 3. Pochette nette, coins arrondis, ombre portée
            let card = layout.cardRect(screenWidth: width, screenHeight: height)
            // CoreGraphics : origine en bas
            let rect = CGRect(x: card.minX, y: height - card.maxY, width: card.width, height: card.height)
            let side = rect.height
            let radius = rect.width * 0.04
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
            let scale = max(rect.width / CGFloat(cover.width), rect.height / CGFloat(cover.height))
            let drawW = CGFloat(cover.width) * scale
            let drawH = CGFloat(cover.height) * scale
            ctx.draw(cover, in: CGRect(x: rect.midX - drawW / 2, y: rect.midY - drawH / 2, width: drawW, height: drawH))
            ctx.restoreGState()

            // Liseré « verre »
            ctx.addPath(path)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
            ctx.setLineWidth(max(1, side * 0.0025))
            ctx.strokePath()
        }

        guard let image = ctx.makeImage() else { return nil }

        // 4. Encodage JPEG
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
