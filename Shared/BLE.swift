import Foundation

/// Trasporto Bluetooth LE: il Mac e' la periferica (pubblica il servizio),
/// l'iPhone/iPad e' la centrale (si collega e scrive i gesti).
///   rx   scrittura dal dispositivo al Mac (write without response)
///   tx   notifiche dal Mac al dispositivo
///   info lettura: macID (16 byte) + nome del Mac
/// I frame sono gli stessi del canale UDP (`Wire`). Se un frame supera la
/// dimensione massima di una scrittura viene spezzato in pezzi con
/// intestazione [0x43 'C'][id][indice][totale].
enum BLE {
    static let service = "7A5C9B10-2F4E-4C8B-9D1A-5E3F6C7D8E90"
    static let rx      = "7A5C9B11-2F4E-4C8B-9D1A-5E3F6C7D8E90"
    static let tx      = "7A5C9B12-2F4E-4C8B-9D1A-5E3F6C7D8E90"
    static let info    = "7A5C9B13-2F4E-4C8B-9D1A-5E3F6C7D8E90"

    static let chunkMagic: UInt8 = 0x43

    static func split(_ frame: Data, max: Int, id: UInt8) -> [Data] {
        guard frame.count > max, max > 4 else { return [frame] }
        let payload = max - 4
        let total = (frame.count + payload - 1) / payload
        return (0..<total).map { i in
            var d = Data([chunkMagic, id, UInt8(i), UInt8(total)])
            d.append(frame.subdata(in: i * payload ..< min((i + 1) * payload, frame.count)))
            return d
        }
    }

    /// Ricompone i pezzi; i frame interi passano subito.
    final class Assembler {
        private var parts: [UInt8: [Int: Data]] = [:]
        func feed(_ d: Data) -> Data? {
            guard d.count >= 4, d[d.startIndex] == chunkMagic else { return d }
            let b = [UInt8](d.prefix(4))
            let id = b[1], idx = Int(b[2]), total = Int(b[3])
            var dict = parts[id] ?? [:]
            dict[idx] = d.dropFirst(4)
            if dict.count == total {
                parts[id] = nil
                var out = Data()
                for i in 0..<total { out.append(dict[i] ?? Data()) }
                return out
            }
            parts[id] = dict
            return nil
        }
    }
}
