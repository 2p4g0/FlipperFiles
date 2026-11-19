import AppKit

let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// y вниз
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func grad(_ p: CGPath, _ top: UInt32, _ bottom: UInt32, _ y0: CGFloat, _ y1: CGFloat) {
    ctx.saveGState(); ctx.addPath(p); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [c(top), c(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    ctx.restoreGState()
}
func fill(_ p: CGPath, _ col: CGColor) { ctx.addPath(p); ctx.setFillColor(col); ctx.fillPath() }
func shadow(_ blur: CGFloat, _ dy: CGFloat, _ a: CGFloat) { ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: c(0, a)) }

// Фон
let bg = rr(100, 100, 824, 824, 185)
ctx.saveGState(); shadow(30, 12, 0.45); fill(bg, c(0x1B1E24)); ctx.restoreGState()
grad(bg, 0x2E333D, 0x14161B, 100, 924)

// Задняя стенка папки
fill(rr(200, 290, 250, 90, 32), c(0xD96400))
fill(rr(200, 335, 624, 450, 48), c(0xD96400))

// Устройство (белый корпус)
let body = rr(262, 250, 500, 330, 78)
ctx.saveGState(); shadow(24, 10, 0.35); fill(body, c(0xFFFFFF)); ctx.restoreGState()
grad(body, 0xFFFFFF, 0xE4E6EA, 250, 580)
// экран
let scr = rr(302, 300, 268, 200, 20)
fill(scr, c(0x2A2A2A))
grad(rr(310, 308, 252, 184, 14), 0xFFA23D, 0xFF8200, 308, 492)
// пиксельный список файлов
let px: CGFloat = 12
let dark = c(0x1A1A1A), orange = c(0xFF8C10)
let rows: [(CGFloat, Int, Bool)] = [(326, 12, true), (376, 9, false), (426, 11, false)]
for (y, len, sel) in rows {
    if sel { fill(CGPath(rect: CGRect(x: 320, y: y - 6, width: 232, height: 48), transform: nil), dark) }
    let fg = sel ? orange : dark
    // папка 3x3 пикселя
    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1), (2, 1), (0, 2), (1, 2), (2, 2)] {
        ctx.setFillColor(fg); ctx.fill(CGRect(x: 332 + CGFloat(dx) * px, y: y + CGFloat(dy) * px, width: px, height: px))
    }
    ctx.setFillColor(fg); ctx.fill(CGRect(x: 386, y: y + 12, width: CGFloat(len) * px, height: px))
}
// D-pad
let cx: CGFloat = 668, cy: CGFloat = 405
ctx.saveGState(); shadow(6, 3, 0.25)
fill(CGPath(ellipseIn: CGRect(x: cx - 72, y: cy - 72, width: 144, height: 144), transform: nil), c(0xD2D5DB))
ctx.restoreGState()
fill(CGPath(ellipseIn: CGRect(x: cx - 64, y: cy - 64, width: 128, height: 128), transform: nil), c(0xEDEFF2))
fill(CGPath(ellipseIn: CGRect(x: cx - 26, y: cy - 26, width: 52, height: 52), transform: nil), c(0xFF8200))

// Передняя стенка папки
let front = rr(180, 470, 664, 340, 52)
ctx.saveGState(); shadow(28, -8, 0.35); fill(front, c(0xFF8200)); ctx.restoreGState()
grad(front, 0xFFAE4A, 0xF06C00, 470, 810)
ctx.saveGState(); ctx.addPath(front); ctx.clip()
ctx.setFillColor(c(0xFFFFFF, 0.28)); ctx.fill(CGRect(x: 180, y: 470, width: 664, height: 6))
ctx.restoreGState()
// стрелки обмена на папке
ctx.setStrokeColor(c(0xFFFFFF, 0.92)); ctx.setLineWidth(26); ctx.setLineCap(.round); ctx.setLineJoin(.round)
for (x, up) in [(452.0, true), (572.0, false)] as [(CGFloat, Bool)] {
    let t: CGFloat = 575, b: CGFloat = 715
    ctx.move(to: CGPoint(x: x, y: t)); ctx.addLine(to: CGPoint(x: x, y: b))
    let tip = up ? t : b, d: CGFloat = up ? 1 : -1
    ctx.move(to: CGPoint(x: x - 38, y: tip + 38 * d)); ctx.addLine(to: CGPoint(x: x, y: tip)); ctx.addLine(to: CGPoint(x: x + 38, y: tip + 38 * d))
    ctx.strokePath()
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
