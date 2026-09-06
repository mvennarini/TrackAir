import Cocoa
// Uso: swift makeicon.swift <out.png> [mac]
// Icona di Tocco: fondo con gradiente blu profondo, superficie del trackpad
// traslucida, un solo punto di contatto con un anello sottile. Niente altro.
let out = CommandLine.arguments[1]
let macStyle = CommandLine.arguments.count > 2
let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

// contenitore: iOS quadrato pieno (iOS lo arrotonda), Mac squircle con margine
let inset: CGFloat = macStyle ? 100 : 0
let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let radius: CGFloat = macStyle ? 185 : 0
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.20, green: 0.47, blue: 1.00, alpha: 1),
    CGColor(red: 0.10, green: 0.22, blue: 0.62, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// superficie del trackpad: rettangolo arrotondato traslucido, proporzione 4:3
let padW = rect.width * 0.66, padH = padW * 0.72
let pad = CGRect(x: rect.midX - padW / 2, y: rect.midY - padH / 2, width: padW, height: padH)
let padPath = CGPath(roundedRect: pad, cornerWidth: 74, cornerHeight: 74, transform: nil)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16)); ctx.addPath(padPath); ctx.fillPath()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35)); ctx.setLineWidth(5)
ctx.addPath(padPath); ctx.strokePath()

// punto di contatto, leggermente in alto a destra del centro, con un anello sottile
let c = CGPoint(x: pad.midX + padW * 0.10, y: pad.midY + padH * 0.06)
// anello: sottile e tenue, come l'onda di un tocco appena avvenuto
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.38)); ctx.setLineWidth(7)
ctx.strokeEllipse(in: CGRect(x: c.x - 132, y: c.y - 132, width: 264, height: 264))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillEllipse(in: CGRect(x: c.x - 54, y: c.y - 54, width: 108, height: 108))
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
