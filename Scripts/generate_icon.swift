// App-icon generator. Draws the Fortiche icon (and alternates) with
// CoreGraphics and writes 1024×1024 PNGs — no external tools needed.
//
//   swift Scripts/generate_icon.swift <output-dir> [concept]
//
// Concepts: "monogram" (default, the shipped icon), "dumbbell", "plate".
// iOS applies its own masking/Liquid Glass treatment; we render a full-bleed
// square with no pre-rounded corners.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024

func makeContext() -> CGContext {
    CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func drawBackground(_ ctx: CGContext, top: UInt32, bottom: UInt32) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [rgb(top), rgb(bottom)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: size / 2, y: size),
        end: CGPoint(x: size / 2, y: 0),
        options: []
    )
}

func rounded(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

/// Soft drop shadow for the glyph so it lifts off the gradient.
func withGlyphShadow(_ ctx: CGContext, _ draw: () -> Void) {
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14),
        blur: 42,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
    )
    draw()
    ctx.restoreGState()
}

// MARK: Concept: "monogram" — an F whose strokes are barbells

func drawMonogram(_ ctx: CGContext) {
    drawBackground(ctx, top: 0x5E5CE6, bottom: 0x2E2C9E) // indigo

    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    let stroke: CGFloat = 118          // bar thickness
    let radius = stroke / 2

    // Geometry (y-up): vertical stem + two horizontal "bars" ending in plates.
    let stemX: CGFloat = 268
    let topBarY: CGFloat = 700
    let midBarY: CGFloat = 452
    let stemBottom: CGFloat = 196

    withGlyphShadow(ctx) {
        // Vertical stem.
        rounded(ctx, CGRect(x: stemX, y: stemBottom, width: stroke, height: topBarY + stroke - stemBottom), radius: radius)
        // Top bar (longer) and middle bar (shorter), like an F.
        rounded(ctx, CGRect(x: stemX, y: topBarY, width: 448, height: stroke), radius: radius)
        rounded(ctx, CGRect(x: stemX, y: midBarY, width: 330, height: stroke), radius: radius)
    }

    // Plates at each bar's right end: inner tall plate + outer shorter plate,
    // the visual signature of a loaded barbell.
    func plates(endingAtX endX: CGFloat, barY: CGFloat) {
        let plateW: CGFloat = 64
        let gap: CGFloat = 26
        let innerH: CGFloat = 330
        let outerH: CGFloat = 240
        let centerY = barY + stroke / 2
        withGlyphShadow(ctx) {
            rounded(ctx, CGRect(x: endX + gap, y: centerY - innerH / 2, width: plateW, height: innerH), radius: 26)
            rounded(ctx, CGRect(x: endX + gap + plateW + 22, y: centerY - outerH / 2, width: plateW, height: outerH), radius: 26)
        }
    }
    plates(endingAtX: stemX + 448, barY: topBarY)
    plates(endingAtX: stemX + 330, barY: midBarY)
}

// MARK: Concept: "dumbbell" — classic 45° dumbbell silhouette (the shipped icon)

func drawDumbbell(_ ctx: CGContext, top: UInt32 = 0x5E5CE6, bottom: UInt32 = 0x2E2C9E) {
    drawBackground(ctx, top: top, bottom: bottom)

    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.translateBy(x: size / 2, y: size / 2)
    ctx.rotate(by: .pi / 4)

    withGlyphShadow(ctx) {
        // Bar, with nubs extending past the outer plates.
        rounded(ctx, CGRect(x: -440, y: -44, width: 880, height: 88), radius: 44)
        // Inner and outer plates, mirrored.
        for side: CGFloat in [-1, 1] {
            rounded(ctx, CGRect(x: side * 250 - 42, y: -190, width: 84, height: 380), radius: 34)
            rounded(ctx, CGRect(x: side * 366 - 42, y: -140, width: 84, height: 280), radius: 34)
        }
    }
}

func drawDumbbellEmber(_ ctx: CGContext) {
    drawDumbbell(ctx, top: 0xFF7A3D, bottom: 0xC1272D)
}

// MARK: Concept: "plate" — end-on weight plate

func drawPlate(_ ctx: CGContext) {
    drawBackground(ctx, top: 0x30D158, bottom: 0x1B7A3D) // green

    let center = CGPoint(x: size / 2, y: size / 2)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    withGlyphShadow(ctx) {
        ctx.addArc(center: center, radius: 340, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.fillPath()
    }
    // Recessed ring + center bore, punched out of the plate.
    ctx.setBlendMode(.clear)
    ctx.setLineWidth(34)
    ctx.addArc(center: center, radius: 236, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.replacePathWithStrokedPath()
    ctx.fillPath()
    ctx.addArc(center: center, radius: 74, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.fillPath()
    ctx.setBlendMode(.normal)
}

// MARK: Main

let args = CommandLine.arguments
let outputDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let registry: [String: (CGContext) -> Void] = [
    "monogram": drawMonogram,
    "dumbbell": { drawDumbbell($0) },
    "dumbbell-ember": drawDumbbellEmber,
    "plate": drawPlate,
]
let concepts: [(String, (CGContext) -> Void)] = args.count > 2
    ? [(args[2], registry[args[2]]!)]
    : registry.map { ($0.key, $0.value) }

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
for (name, draw) in concepts {
    let ctx = makeContext()
    draw(ctx)
    let url = outputDir.appendingPathComponent("icon-\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}
