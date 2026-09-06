import Foundation

/// Protocollo TrackAir: datagrammi UDP da 9 byte
///   [tipo: UInt8][a: Float32 LE][b: Float32 LE]
/// Il messaggio `hello` puo' avere in coda il nome del dispositivo in UTF-8.
enum MsgType: UInt8 {
    case move = 1         // a = dx, b = dy (pixel schermo Mac)
    case scroll = 2       // a = dx, b = dy: scorrimento con le dita sul trackpad
    case button = 3       // a = tasto (0 sinistro, 1 destro), b = 1 premuto / 0 rilasciato
    case hello = 4        // keepalive + nome dispositivo
    case key = 5          // a = keycode macOS (kVK_*), b = modificatori (bit: 1 cmd, 2 ctrl, 4 alt, 8 shift)
    case scrollEnd = 7    // le dita si sono alzate
    case momentum = 8     // a = dx, b = dy: inerzia dopo il rilascio
    case momentumEnd = 9  // fine dell'inerzia
    case action = 10      // a = azione di sistema (vedi Action)
    case text = 11        // testo UTF-8 in coda (come il nome in hello): viene digitato sul Mac
}

enum Mod {
    static let cmd: Float = 1, ctrl: Float = 2, alt: Float = 4, shift: Float = 8
}

/// Tasti virtuali macOS usati dai gesti
enum VK {
    static let left: Float = 123, right: Float = 124, down: Float = 125, up: Float = 126
    static let equal: Float = 24, minus: Float = 27
    static let returnKey: Float = 36, tab: Float = 48, space: Float = 49, delete: Float = 51, escape: Float = 53
    static let forwardDelete: Float = 117, home: Float = 115, end: Float = 119, pageUp: Float = 116, pageDown: Float = 121

    /// Tasti macOS (layout ANSI) per i caratteri ASCII: servono per le scorciatoie (Cmd+C ecc.).
    static let ascii: [Character: Float] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49
    ]
}

enum Action {
    static let missionControl: Float = 1
    static let appExpose: Float = 2
    static let showDesktop: Float = 3
    static let dismissMissionControl: Float = 4   // 4 dita in giu': chiude Mission Control se aperto
    static let launchpad: Float = 5               // pizzico a 4 dita che si chiude: vista App (Launchpad)
    static let closeLaunchpad: Float = 6          // pizzico a 4 dita che si allarga: chiude la vista App
}

struct Msg {
    var type: MsgType
    var a: Float = 0
    var b: Float = 0
    var name: String? = nil

    static let serviceType = "_trackair._udp"

    func encode() -> Data {
        var d = Data(capacity: 9 + (name?.utf8.count ?? 0))
        d.append(type.rawValue)
        var ab = a.bitPattern.littleEndian
        var bb = b.bitPattern.littleEndian
        withUnsafeBytes(of: &ab) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: &bb) { d.append(contentsOf: $0) }
        if let name { d.append(contentsOf: Array(name.utf8)) }
        return d
    }

    static func decode(_ d: Data) -> Msg? {
        guard d.count >= 9, let t = MsgType(rawValue: d[d.startIndex]) else { return nil }
        let bytes = [UInt8](d)
        func f(_ o: Int) -> Float {
            let u = UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 | UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24
            return Float(bitPattern: u)
        }
        var m = Msg(type: t, a: f(1), b: f(5))
        if bytes.count > 9 { m.name = String(decoding: bytes[9...], as: UTF8.self) }
        return m
    }
}
