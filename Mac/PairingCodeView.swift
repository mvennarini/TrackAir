import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Matrice dei moduli di un codice QR (true = scuro), letta dall'immagine di CoreImage.
enum QRMatrix {
    static func make(_ text: String) -> [[Bool]] {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let img = f.outputImage,
              let cg = CIContext().createCGImage(img, from: img.extent) else { return [] }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func dark(_ x: Int, _ y: Int) -> Bool { px[(y * w + x) * 4] < 128 }
        // taglia la zona di quiete: primo/ultimo modulo scuro
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where dark(x, y) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        guard maxX >= minX else { return [] }
        // nel buffer di CGBitmapContext la riga 0 e' quella in alto: nessuna inversione
        return (minY...maxY).map { y in (minX...maxX).map { x in dark(x, y) } }
    }
}

/// Il codice come nuvola di punti luminosi che respira su fondo scuro, con
/// particelle in movimento intorno. I tre riquadri di riferimento restano
/// pieni e fermi: sono quelli che la fotocamera usa per agganciare il codice.
struct PairingCodeView: View {
    let payload: String
    var successAt: Date? = nil
    private let matrix: [[Bool]]
    private let particles: [(angle: Double, radius: Double, speed: Double, size: Double, phase: Double)]

    init(payload: String, successAt: Date? = nil) {
        self.payload = payload
        self.successAt = successAt
        matrix = QRMatrix.make(payload)
        var g = SystemRandomNumberGenerator()
        particles = (0..<90).map { _ in
            (Double.random(in: 0..<(2 * .pi), using: &g), Double.random(in: 0.52...0.72, using: &g),
             Double.random(in: 0.08...0.35, using: &g) * (Bool.random(using: &g) ? 1 : -1),
             Double.random(in: 1.5...4.5, using: &g), Double.random(in: 0..<(2 * .pi), using: &g))
        }
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let n = matrix.count
                guard n > 0 else { return }
                let side = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let glow = Color(red: 0.45, green: 0.78, blue: 1.0)
                // avanzamento dell'animazione di successo: 0 = nuvola, 1 = anello con spunta
                let elapsed = successAt.map { tl.date.timeIntervalSince($0) } ?? -1
                let raw = min(max(elapsed / 0.9, 0), 1)
                let p = elapsed < 0 ? 0 : 1 - pow(1 - raw, 3)          // ease-out
                let burst = elapsed < 0 ? 0 : min(max((elapsed - 0.2) / 1.2, 0), 1)

                // alone morbido dietro alla nuvola
                let halo = side * 0.42
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - halo, y: center.y - halo, width: 2 * halo, height: 2 * halo)),
                         with: .radialGradient(Gradient(colors: [glow.opacity(0.16), .clear]), center: center, startRadius: 0, endRadius: halo))

                // particelle in orbita, che si accendono e si spengono
                for q in particles {
                    let a = q.angle + t * q.speed
                    // al successo le particelle esplodono verso l'esterno e svaniscono
                    let r = q.radius * side * (1 + 0.025 * sin(t * 1.1 + q.phase)) + burst * side * 0.5
                    let pt = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
                    let alpha = (0.15 + 0.6 * (0.5 + 0.5 * sin(t * 1.7 + q.phase))) * (1 - burst)
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - q.size / 2, y: pt.y - q.size / 2, width: q.size, height: q.size)),
                             with: .color(glow.opacity(alpha)))
                }

                // moduli: zona di quiete scura intorno, punti chiari
                let code = side * 0.62
                let quiet = 2.0
                let m = code / Double(n)
                let origin = CGPoint(x: center.x - code / 2, y: center.y - code / 2)
                _ = quiet   // la zona di quiete e' garantita tenendo le particelle oltre il 52% del lato
                func isFinder(_ x: Int, _ y: Int) -> Bool {
                    (x < 7 && y < 7) || (x >= n - 7 && y < 7) || (x < 7 && y >= n - 7)
                }
                let ringR = side * 0.17
                var index = 0
                let total = matrix.reduce(0) { $0 + $1.filter { $0 }.count }
                for y in 0..<n {
                    for x in 0..<n where matrix[y][x] {
                        var cx = origin.x + (Double(x) + 0.5) * m
                        var cy = origin.y + (Double(y) + 0.5) * m
                        if p > 0 {
                            // ogni punto converge verso la sua posizione sull'anello
                            let ang = Double(index) / Double(max(total, 1)) * 2 * .pi + p * 0.6
                            let tx = center.x + cos(ang) * ringR, ty = center.y + sin(ang) * ringR
                            cx += (tx - cx) * p; cy += (ty - cy) * p
                        }
                        index += 1
                        if isFinder(x, y) && p == 0 {
                            // anche i riferimenti sono punti, appena piu' grandi e chiari, cosi' tutto e' nuvola
                            let r = m * 0.5
                            ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                                     with: .color(Color(red: 0.80, green: 0.92, blue: 1.0)))
                        } else {
                            let d = hypot(Double(x) - Double(n) / 2, Double(y) - Double(n) / 2) / (Double(n) / 2)
                            let breathe = 0.36 + 0.07 * sin(t * 2.0 - d * 5)
                            let r = m * breathe * (1 - 0.35 * p)
                            // alone leggero e punto pieno
                            ctx.fill(Path(ellipseIn: CGRect(x: cx - r * 1.8, y: cy - r * 1.8, width: 3.6 * r, height: 3.6 * r)), with: .color(glow.opacity(0.10)))
                            ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)), with: .color(glow.opacity(0.95)))
                        }
                    }
                }
                if elapsed > 0.7 {
                    // anello pieno e segno di spunta che si disegna
                    let k = min(max((elapsed - 0.7) / 0.5, 0), 1)
                    ctx.stroke(Path(ellipseIn: CGRect(x: center.x - ringR, y: center.y - ringR, width: 2 * ringR, height: 2 * ringR)),
                               with: .color(glow.opacity(0.9 * k)), lineWidth: 3)
                    var check = Path()
                    check.move(to: CGPoint(x: center.x - ringR * 0.42, y: center.y + ringR * 0.02))
                    check.addLine(to: CGPoint(x: center.x - ringR * 0.10, y: center.y + ringR * 0.34))
                    check.addLine(to: CGPoint(x: center.x + ringR * 0.48, y: center.y - ringR * 0.30))
                    ctx.stroke(check.trimmedPath(from: 0, to: k), with: .color(.white),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(String(localized: "Pairing code"))
    }
}
