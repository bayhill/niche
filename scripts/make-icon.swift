// Draws the Notcher app icon and writes a 1024×1024 PNG.  Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

// macOS icon grid: 824 pt body centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(bodyPath); ctx.setFillColor(rgb(0.05, 0.06, 0.10)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()

// Background: deep blue-black, lit from above.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0.13, 0.18, 0.32), rgb(0.05, 0.07, 0.14), rgb(0.02, 0.03, 0.06)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
let glow = CGGradient(colorsSpace: space, colors: [rgb(0.25, 0.62, 1.0, 0.55), rgb(0.25, 0.62, 1.0, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 610), startRadius: 0, endCenter: CGPoint(x: 512, y: 610), endRadius: 430, options: [])

// The image card being drawn up into the notch.
let card = CGRect(x: 512 - 190, y: 300, width: 380, height: 300)
ctx.saveGState()
ctx.translateBy(x: 512, y: 450); ctx.rotate(by: -0.10); ctx.translateBy(x: -512, y: -450)
let cardPath = CGPath(roundedRect: card, cornerWidth: 54, cornerHeight: 54, transform: nil)
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0, 0, 0, 0.45))
ctx.addPath(cardPath); ctx.setFillColor(rgb(0.2, 0.5, 1)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.addPath(cardPath); ctx.clip()
let cardFill = CGGradient(colorsSpace: space, colors: [rgb(0.45, 0.80, 1.0), rgb(0.22, 0.52, 1.0), rgb(0.30, 0.36, 0.95)] as CFArray, locations: [0, 0.6, 1])!
ctx.drawLinearGradient(cardFill, start: CGPoint(x: card.minX, y: card.maxY), end: CGPoint(x: card.maxX, y: card.minY), options: [])
// Landscape glyph: sun and two hills.
ctx.setFillColor(rgb(1, 1, 1, 0.95))
ctx.fillEllipse(in: CGRect(x: card.minX + 62, y: card.maxY - 128, width: 62, height: 62))
let hills = CGMutablePath()
hills.move(to: CGPoint(x: card.minX - 10, y: card.minY - 10))
hills.addLine(to: CGPoint(x: card.minX + 10, y: card.minY + 70))
hills.addQuadCurve(to: CGPoint(x: card.minX + 170, y: card.minY + 120), control: CGPoint(x: card.minX + 100, y: card.minY + 190))
hills.addQuadCurve(to: CGPoint(x: card.minX + 262, y: card.minY + 150), control: CGPoint(x: card.minX + 205, y: card.minY + 95))
hills.addQuadCurve(to: CGPoint(x: card.maxX + 10, y: card.minY + 60), control: CGPoint(x: card.minX + 320, y: card.minY + 235))
hills.addLine(to: CGPoint(x: card.maxX + 10, y: card.minY - 10))
hills.closeSubpath()
ctx.addPath(hills); ctx.setFillColor(rgb(1, 1, 1, 0.92)); ctx.fillPath()
// Glass sheen across the top of the card.
let sheen = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.38), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: card.maxY), end: CGPoint(x: 512, y: card.maxY - 150), options: [])
ctx.restoreGState()
ctx.saveGState()
ctx.translateBy(x: 512, y: 450); ctx.rotate(by: -0.10); ctx.translateBy(x: -512, y: -450)
ctx.addPath(cardPath); ctx.setStrokeColor(rgb(1, 1, 1, 0.45)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

// The notch: black, hanging from the top edge, with concave ears.
let nw: CGFloat = 400, nh: CGFloat = 132, ear: CGFloat = 26, r: CGFloat = 50
let top = body.maxY, left = 512 - nw / 2, right = 512 + nw / 2
let notch = CGMutablePath()
notch.move(to: CGPoint(x: left - ear, y: top + 2))
notch.addQuadCurve(to: CGPoint(x: left, y: top - ear), control: CGPoint(x: left, y: top))
notch.addLine(to: CGPoint(x: left, y: top - nh + r))
notch.addQuadCurve(to: CGPoint(x: left + r, y: top - nh), control: CGPoint(x: left, y: top - nh))
notch.addLine(to: CGPoint(x: right - r, y: top - nh))
notch.addQuadCurve(to: CGPoint(x: right, y: top - nh + r), control: CGPoint(x: right, y: top - nh))
notch.addLine(to: CGPoint(x: right, y: top - ear))
notch.addQuadCurve(to: CGPoint(x: right + ear, y: top + 2), control: CGPoint(x: right, y: top))
notch.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0.25, 0.62, 1.0, 0.55))
ctx.addPath(notch); ctx.setFillColor(rgb(0, 0, 0)); ctx.fillPath()
ctx.restoreGState()

// Top-edge highlight on the body.
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(1, 1, 1, 0.14)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
