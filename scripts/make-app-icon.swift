// make-app-icon.swift — renders the app icon (1024×1024 PNG): a GPS route
// polyline on a bright coral→amber gradient — running-app coded, matches the
// in-app route maps.
//
//   swift scripts/make-app-icon.swift
//
// Writes ios/PainEnjoyer/Assets.xcassets/AppIcon.appiconset/icon.png

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

// bright diagonal gradient: coral → amber
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    colors: [rgb(1.00, 0.36, 0.15), rgb(1.00, 0.70, 0.20)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0),
                       end: CGPoint(x: 1024, y: 1024), options: [])

// the route: a rounded polyline sweeping bottom-left → top-right
let pts: [CGPoint] = [
    CGPoint(x: 200, y: 220),
    CGPoint(x: 430, y: 330),
    CGPoint(x: 330, y: 540),
    CGPoint(x: 620, y: 640),
    CGPoint(x: 540, y: 800),
    CGPoint(x: 824, y: 820),
]
let path = CGMutablePath()
path.move(to: pts[0])
for p in pts.dropFirst() { path.addLine(to: p) }

// soft shadow pass under the route
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: rgb(0.55, 0.12, 0.0, 0.45))
ctx.addPath(path)
ctx.setStrokeColor(rgb(1, 1, 1))
ctx.setLineWidth(58)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// start dot (filled) + finish ring
ctx.setFillColor(rgb(1, 1, 1))
ctx.fillEllipse(in: CGRect(x: pts[0].x - 56, y: pts[0].y - 56, width: 112, height: 112))
ctx.setFillColor(rgb(1.00, 0.42, 0.18))
ctx.fillEllipse(in: CGRect(x: pts[0].x - 26, y: pts[0].y - 26, width: 52, height: 52))

let end = pts.last!
ctx.setStrokeColor(rgb(1, 1, 1))
ctx.setLineWidth(34)
ctx.strokeEllipse(in: CGRect(x: end.x - 62, y: end.y - 62, width: 124, height: 124))

let img = ctx.makeImage()!
let out = URL(fileURLWithPath: "ios/PainEnjoyer/Assets.xcassets/AppIcon.appiconset/icon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed") }
print("wrote \(out.path)")
