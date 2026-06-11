// make-app-icon.swift — renders the app icon (1024×1024 PNG): a glowing
// traffic light on dark slate. The 🔴🟡🟢 push/pull light IS the brand.
//
//   swift scripts/make-app-icon.swift
//
// Writes ios/PainEnjoyer/Assets.xcassets/AppIcon.appiconset/icon.png
// (committed; re-run only to restyle).

import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let size = 1024
let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

// background: deep slate vertical gradient
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: [rgb(0.075, 0.085, 0.11), rgb(0.13, 0.15, 0.19)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 1024),
                       end: CGPoint(x: 512, y: 0), options: [])

// housing: a soft pill behind the lights
let housing = CGRect(x: 330, y: 96, width: 364, height: 832)
let pill = CGPath(roundedRect: housing, cornerWidth: 182, cornerHeight: 182, transform: nil)
ctx.addPath(pill)
ctx.setFillColor(rgb(0.055, 0.06, 0.08, 0.85))
ctx.fillPath()

// the three lights, glowing
let lights: [(y: CGFloat, color: CGColor)] = [
    (756, rgb(1.00, 0.27, 0.23)),  // red on top
    (512, rgb(1.00, 0.84, 0.04)),
    (268, rgb(0.19, 0.82, 0.35)),
]
for l in lights {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: l.color.copy(alpha: 0.85))
    ctx.setFillColor(l.color)
    ctx.fillEllipse(in: CGRect(x: 512 - 104, y: l.y - 104, width: 208, height: 208))
    ctx.restoreGState()
    // specular highlight
    ctx.setFillColor(rgb(1, 1, 1, 0.28))
    ctx.fillEllipse(in: CGRect(x: 512 - 58, y: l.y + 18, width: 64, height: 52))
}

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: "ios/PainEnjoyer/Assets.xcassets/AppIcon.appiconset/icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
print("wrote \(out.path)")
