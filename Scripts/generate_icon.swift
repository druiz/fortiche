// App-icon generator. Draws the Fortiche icon set with CoreGraphics and
// writes 1024×1024 PNGs — no external tools needed.
//
// Regenerate everything (primary icon, alternate colorways, in-app previews,
// watch icon) straight into the asset catalogs:
//
//   swift Scripts/generate_icon.swift --catalog
//
// Or render individual concepts to a directory for eyeballing:
//
//   swift Scripts/generate_icon.swift <output-dir> [concept]
//
// iOS applies its own masking/Liquid Glass treatment; we render a full-bleed
// square with no pre-rounded corners.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024

// MARK: - Colorways

/// The selectable icon colorways. Order here drives nothing at runtime —
/// the app lists them explicitly in SettingsView — but names must match:
/// asset "AppIcon[-Name]" and preview "IconPreview-Name".
let colorways: [(name: String, top: UInt32, bottom: UInt32, glyph: UInt32)] = [
    ("Indigo", 0x5E5CE6, 0x2E2C9E, 0xFFFFFF),   // default
    ("Ember", 0xFF7A3D, 0xC1272D, 0xFFFFFF),
    ("Forest", 0x30D158, 0x146B33, 0xFFFFFF),
    ("Midnight", 0x3A3A3C, 0x0B0B0F, 0xFFFFFF),
    ("Ivory", 0xF5F5F7, 0xD8D8DF, 0x4B49C8),
]

// MARK: - Drawing primitives

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

/// Soft drop shadow so the glyph lifts off the gradient.
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

// MARK: - The icon: 45° dumbbell

func drawDumbbell(_ ctx: CGContext, top: UInt32, bottom: UInt32, glyph: UInt32) {
    drawBackground(ctx, top: top, bottom: bottom)

    ctx.setFillColor(rgb(glyph))
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

func render(top: UInt32, bottom: UInt32, glyph: UInt32) -> CGImage {
    let ctx = makeContext()
    drawDumbbell(ctx, top: top, bottom: bottom, glyph: glyph)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

func writeJSON(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Catalog emission

/// Writes the primary icon, alternate-icon sets, preview image sets, and the
/// watch icon into the asset catalogs. Idempotent — safe to re-run.
func emitCatalogs(repoRoot: URL) {
    let iosCatalog = repoRoot.appending(path: "Fortiche/Assets.xcassets")
    let watchCatalog = repoRoot.appending(path: "ForticheWatch/Assets.xcassets")

    func appIconContents(filename: String, platform: String) -> String {
        """
        {
          "images" : [
            {
              "filename" : "\(filename)",
              "idiom" : "universal",
              "platform" : "\(platform)",
              "size" : "1024x1024"
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
    }

    func imageSetContents(filename: String) -> String {
        """
        {
          "images" : [
            { "filename" : "\(filename)", "idiom" : "universal" }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
    }

    for (index, colorway) in colorways.enumerated() {
        let image = render(top: colorway.top, bottom: colorway.bottom, glyph: colorway.glyph)
        // First colorway is the primary "AppIcon"; the rest are alternates
        // named AppIcon-<Name> (must match ASSETCATALOG_COMPILER_ALTERNATE_
        // APPICON_NAMES in project.yml and the SettingsView list).
        let setName = index == 0 ? "AppIcon" : "AppIcon-\(colorway.name)"
        let iconSet = iosCatalog.appending(path: "\(setName).appiconset")
        writePNG(image, to: iconSet.appending(path: "AppIcon.png"))
        writeJSON(appIconContents(filename: "AppIcon.png", platform: "ios"), to: iconSet.appending(path: "Contents.json"))

        // Preview image for the in-app picker (alternate appiconsets aren't
        // loadable via UIImage(named:), so each colorway also ships as a
        // regular image set).
        let previewSet = iosCatalog.appending(path: "IconPreview-\(colorway.name).imageset")
        writePNG(image, to: previewSet.appending(path: "preview.png"))
        writeJSON(imageSetContents(filename: "preview.png"), to: previewSet.appending(path: "Contents.json"))
    }

    // Watch: alternate icons aren't supported on watchOS — default only.
    let defaultColorway = colorways[0]
    let watchImage = render(top: defaultColorway.top, bottom: defaultColorway.bottom, glyph: defaultColorway.glyph)
    let watchSet = watchCatalog.appending(path: "AppIcon.appiconset")
    writePNG(watchImage, to: watchSet.appending(path: "AppIcon.png"))
    writeJSON(appIconContents(filename: "AppIcon.png", platform: "watchos"), to: watchSet.appending(path: "Contents.json"))
}

// MARK: - Main

let args = CommandLine.arguments
if args.contains("--catalog") {
    // Repo root = parent of Scripts/.
    let root = URL(fileURLWithPath: args[0]).deletingLastPathComponent().deletingLastPathComponent()
    emitCatalogs(repoRoot: root)
} else {
    let outputDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
    let wanted = args.count > 2 ? [args[2]] : colorways.map(\.name)
    for colorway in colorways where wanted.contains(colorway.name) {
        writePNG(
            render(top: colorway.top, bottom: colorway.bottom, glyph: colorway.glyph),
            to: outputDir.appending(path: "icon-\(colorway.name).png")
        )
    }
}
