// Renders the IPA Courier app icon. Usage: swift scripts/make-icon.swift out.png [size]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let px = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let s = CGFloat(px) / 1024

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let g = NSGraphicsContext(bitmapImageRep: rep)!
let c = g.cgContext
// Work in a 1024 canvas with the origin at the top left.
c.scaleBy(x: s, y: s)
c.translateBy(x: 0, y: 1024)
c.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}
func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func fill(_ path: CGPath, _ grad: CGGradient, from: CGPoint, to: CGPoint) {
    c.saveGState(); c.addPath(path); c.clip()
    c.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}
func shadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) {
    // y is flipped, so a positive offset in the CG sense points up: negate.
    c.setShadow(offset: CGSize(width: 0, height: -dy * s), blur: blur * s, color: rgb(0x000000, alpha))
}

// Background squircle (macOS icon grid: 824 pt body inset 100).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = rr(body, 185)
c.saveGState(); shadow(28, 12, 0.35); c.addPath(bodyPath); c.setFillColor(rgb(0x2B47D8)); c.fillPath(); c.restoreGState()
fill(bodyPath, gradient([rgb(0x4C8DFF), rgb(0x2D3FD0)]), from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
// Soft highlight in the top half.
c.saveGState(); c.addPath(bodyPath); c.clip()
c.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)]),
                     startCenter: CGPoint(x: 400, y: 160), startRadius: 0,
                     endCenter: CGPoint(x: 400, y: 160), endRadius: 620, options: [])
c.restoreGState()

// Phone.
let phone = CGRect(x: 488, y: 214, width: 296, height: 560)
c.saveGState(); shadow(30, 16, 0.35); c.addPath(rr(phone, 64)); c.setFillColor(rgb(0xF4F7FF)); c.fillPath(); c.restoreGState()
fill(rr(phone, 64), gradient([rgb(0xFFFFFF), rgb(0xDDE6FA)]), from: CGPoint(x: 0, y: phone.minY), to: CGPoint(x: 0, y: phone.maxY))
let screen = phone.insetBy(dx: 22, dy: 22)
fill(rr(screen, 44), gradient([rgb(0x1B2A6B), rgb(0x0E1640)]), from: CGPoint(x: 0, y: screen.minY), to: CGPoint(x: 0, y: screen.maxY))
// Dynamic Island.
c.addPath(rr(CGRect(x: phone.midX - 46, y: screen.minY + 18, width: 92, height: 26), 13)); c.setFillColor(rgb(0x000000, 0.85)); c.fillPath()
// App tiles on the screen.
let tileColors: [UInt32] = [0x5AC8FA, 0x34C759, 0xFF9F0A, 0xBF5AF2, 0xFF375F, 0x64D2FF]
for i in 0..<6 {
    let col = CGFloat(i % 3), row = CGFloat(i / 3)
    let t = CGRect(x: screen.minX + 28 + col * 70, y: screen.minY + 76 + row * 72, width: 52, height: 52)
    c.addPath(rr(t, 14)); c.setFillColor(rgb(tileColors[i], 0.9)); c.fillPath()
}

// Speed lines behind the parcel.
c.setLineCap(.round)
for (y, x0, x1, w) in [(520.0, 168.0, 300.0, 22.0), (590.0, 140.0, 290.0, 22.0), (660.0, 180.0, 300.0, 22.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    c.setStrokeColor(rgb(0xFFFFFF, 0.85)); c.setLineWidth(w)
    c.move(to: CGPoint(x: x0, y: y)); c.addLine(to: CGPoint(x: x1, y: y)); c.strokePath()
}

// Parcel, overlapping the phone's lower left.
let box = CGRect(x: 268, y: 446, width: 330, height: 300)
let boxPath = rr(box, 34)
c.saveGState(); shadow(34, 20, 0.4); c.addPath(boxPath); c.setFillColor(rgb(0xF59A23)); c.fillPath(); c.restoreGState()
fill(boxPath, gradient([rgb(0xFFC15A), rgb(0xF08A12)]), from: CGPoint(x: 0, y: box.minY), to: CGPoint(x: 0, y: box.maxY))
// Lid seam.
c.saveGState(); c.addPath(boxPath); c.clip()
c.setFillColor(rgb(0xB85F00, 0.28)); c.fill(CGRect(x: box.minX, y: box.minY + 84, width: box.width, height: 8))
c.setFillColor(rgb(0xFFFFFF, 0.25)); c.fill(CGRect(x: box.minX, y: box.minY + 92, width: box.width, height: 4))
// Tape.
let tape = CGRect(x: box.midX - 32, y: box.minY, width: 64, height: box.height)
fill(CGPath(rect: tape, transform: nil), gradient([rgb(0xFFE3A6), rgb(0xF7C772)]), from: CGPoint(x: 0, y: box.minY), to: CGPoint(x: 0, y: box.maxY))
c.restoreGState()
// Shipping label with a down arrow ("install").
let label = CGRect(x: box.minX + 34, y: box.minY + 134, width: 96, height: 120)
c.addPath(rr(label, 14)); c.setFillColor(rgb(0xFFFFFF, 0.95)); c.fillPath()
c.setStrokeColor(rgb(0x2D3FD0)); c.setLineWidth(12); c.setLineJoin(.round)
c.move(to: CGPoint(x: label.midX, y: label.minY + 26)); c.addLine(to: CGPoint(x: label.midX, y: label.maxY - 30)); c.strokePath()
c.move(to: CGPoint(x: label.midX - 24, y: label.maxY - 52)); c.addLine(to: CGPoint(x: label.midX, y: label.maxY - 28))
c.addLine(to: CGPoint(x: label.midX + 24, y: label.maxY - 52)); c.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
