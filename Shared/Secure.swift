import Foundation
import CryptoKit
import Security

// ============================================================
//  Livello sicuro di TrackAir (protocollo v2)
//
//  Ogni datagramma: [magic 'T'][versione 2][tipo][corpo]
//   tipo 1 data          corpo = peerID(16) + box ChaCha20-Poly1305 (nonce 12 + cifrato + tag 16)
//   tipo 2 pairKnock     corpo = deviceID(16) + nome (chiede al Mac di mostrare il PIN)
//   tipo 3 pairRequest   corpo = deviceID(16) + pub(32) + hmac(32) + nome
//   tipo 4 needPairing   corpo = macID(16)
//   tipo 5 pairResponse  corpo = macID(16) + macPub(32) + hmac(32) + nome
//   tipo 7 pairFailed    corpo = motivo (utf8)
//
//  Abbinamento: PIN a 6 cifre mostrato dal Mac; scambio di chiavi Curve25519
//  autenticato con HMAC del PIN; chiave di sessione derivata con HKDF.
//  Dati: cifrati e autenticati; il nonce e' sessione(4)+contatore(8), il
//  ricevente rifiuta contatori non crescenti (nessun replay). Due chiavi
//  distinte per le due direzioni.
// ============================================================

enum Wire {
    static let magic: UInt8 = 0x54
    static let version: UInt8 = 2
    static let headerLength = 3

    enum Kind: UInt8 {
        case data = 1
        case pairKnock = 2      // corpo = deviceID(16) + nome: "mostrami il PIN"
        case pairRequest = 3
        case needPairing = 4
        case pairResponse = 5
        case pairFailed = 7
    }

    static func frame(_ kind: Kind, _ body: Data) -> Data {
        var d = Data([magic, version, kind.rawValue])
        d.append(body)
        return d
    }

    static func parse(_ d: Data) -> (kind: Kind, body: Data)? {
        guard d.count >= headerLength else { return nil }
        let b = [UInt8](d.prefix(headerLength))
        guard b[0] == magic, b[1] == version, let k = Kind(rawValue: b[2]) else { return nil }
        return (k, d.dropFirst(headerLength))
    }
}

// MARK: - Identita' e archivio dei dispositivi abbinati

enum LocalIdentity {
    private static let key = "trackair.localIdentity"
    static var id: UUID {
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return u
    }
}

struct PeerRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var sendKey: Data      // chiave per i pacchetti che INVIO a questo peer
    var receiveKey: Data   // chiave per i pacchetti che RICEVO da questo peer
    var pairedAt: Date
    var lastSeen: Date?
}

/// Archivio su file (JSON) con permessi ristretti. Sul Mac in Application
/// Support, su iOS nel contenitore dell'app con protezione dati completa.
final class PeerStore {
    private let url: URL
    private(set) var peers: [PeerRecord] = []
    private let queue = DispatchQueue(label: "trackair.peerstore")

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("peers.json")
        load()
    }

    private func load() {
        guard let d = try? Data(contentsOf: url) else { return }
        peers = (try? JSONDecoder().decode([PeerRecord].self, from: d)) ?? []
    }

    private func persist() {
        queue.sync {
            let d = (try? JSONEncoder().encode(peers)) ?? Data()
            var opts: Data.WritingOptions = [.atomic]
            #if os(iOS)
            opts.insert(.completeFileProtection)
            #endif
            try? d.write(to: url, options: opts)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func peer(_ id: UUID) -> PeerRecord? { peers.first { $0.id == id } }

    func upsert(_ p: PeerRecord) {
        peers.removeAll { $0.id == p.id }
        peers.append(p)
        persist()
    }

    func touch(_ id: UUID) {
        if let i = peers.firstIndex(where: { $0.id == id }) {
            peers[i].lastSeen = Date()
            persist()
        }
    }

    func remove(_ id: UUID) {
        peers.removeAll { $0.id == id }
        persist()
    }
}

// MARK: - Abbinamento

enum Pairing {
    static let pinLength = 6

    static func randomPIN() -> String {
        (0..<pinLength).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// Segreto da 128 bit per l'abbinamento tramite codice inquadrato con la fotocamera.
    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func fromBase64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Contenuto del codice mostrato dal Mac: "T" + base64url(macID 16 byte + segreto 16 byte).
    /// Corto apposta: meno moduli, punti piu' grandi.
    static func codePayload(macID: UUID, secret: String) -> String {
        var d = macID.data
        d.append(fromBase64url(secret) ?? Data())
        return "T" + base64url(d)
    }

    static func parseCode(_ text: String) -> (macID: UUID, secret: String)? {
        guard text.hasPrefix("T"), let d = fromBase64url(String(text.dropFirst())), d.count == 32,
              let id = UUID(data: d.prefix(16)) else { return nil }
        return (id, base64url(d.suffix(16)))
    }

    /// Chiave derivata dal PIN (o dal segreto del codice), legata all'ID del dispositivo.
    static func pinKey(pin: String, deviceID: UUID) -> SymmetricKey {
        var input = Data(pin.utf8)
        input.append(deviceID.data)
        input.append(Data("tocco-pair-v2".utf8))
        return SymmetricKey(data: SHA256.hash(data: input))
    }

    static func mac(_ key: SymmetricKey, _ parts: Data...) -> Data {
        var d = Data()
        parts.forEach { d.append($0) }
        return Data(HMAC<SHA256>.authenticationCode(for: d, using: key))
    }

    static func verify(_ tag: Data, _ key: SymmetricKey, _ parts: Data...) -> Bool {
        var d = Data()
        parts.forEach { d.append($0) }
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: d, using: key)
    }

    /// Deriva le due chiavi di direzione dal segreto condiviso.
    /// `initiator` = il dispositivo che ha chiesto l'abbinamento (iPhone/iPad).
    static func deriveKeys(shared: SharedSecret, deviceID: UUID, macID: UUID)
        -> (deviceToMac: SymmetricKey, macToDevice: SymmetricKey) {
        var salt = deviceID.data
        salt.append(macID.data)
        let a = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                               sharedInfo: Data("tocco-v2-device-to-mac".utf8), outputByteCount: 32)
        let b = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                               sharedInfo: Data("tocco-v2-mac-to-device".utf8), outputByteCount: 32)
        return (a, b)
    }

    // --- corpi dei messaggi ---

    struct Request {
        var deviceID: UUID
        var publicKey: Data
        var tag: Data
        var name: String

        static func make(deviceID: UUID, name: String, pin: String, privateKey: Curve25519.KeyAgreement.PrivateKey) -> Data {
            let pub = privateKey.publicKey.rawRepresentation
            let nameData = Data(name.utf8)
            let tag = mac(pinKey(pin: pin, deviceID: deviceID), deviceID.data, pub, nameData)
            var body = deviceID.data
            body.append(pub); body.append(tag); body.append(nameData)
            return Wire.frame(.pairRequest, body)
        }

        static func parse(_ body: Data) -> Request? {
            guard body.count >= 16 + 32 + 32 else { return nil }
            let b = Data(body)
            return Request(deviceID: UUID(data: b.prefix(16))!,
                           publicKey: b.subdata(in: 16..<48),
                           tag: b.subdata(in: 48..<80),
                           name: String(decoding: b.dropFirst(80), as: UTF8.self))
        }

        func isValid(pin: String) -> Bool {
            verify(tag, pinKey(pin: pin, deviceID: deviceID), deviceID.data, publicKey, Data(name.utf8))
        }
    }

    struct Response {
        var macID: UUID
        var publicKey: Data
        var tag: Data
        var name: String

        static func make(macID: UUID, name: String, deviceID: UUID, pin: String, privateKey: Curve25519.KeyAgreement.PrivateKey) -> Data {
            let pub = privateKey.publicKey.rawRepresentation
            let nameData = Data(name.utf8)
            let tag = mac(pinKey(pin: pin, deviceID: deviceID), macID.data, pub, deviceID.data, nameData)
            var body = macID.data
            body.append(pub); body.append(tag); body.append(nameData)
            return Wire.frame(.pairResponse, body)
        }

        static func parse(_ body: Data) -> Response? {
            guard body.count >= 16 + 32 + 32 else { return nil }
            let b = Data(body)
            return Response(macID: UUID(data: b.prefix(16))!,
                            publicKey: b.subdata(in: 16..<48),
                            tag: b.subdata(in: 48..<80),
                            name: String(decoding: b.dropFirst(80), as: UTF8.self))
        }

        func isValid(pin: String, deviceID: UUID) -> Bool {
            verify(tag, pinKey(pin: pin, deviceID: deviceID), macID.data, publicKey, deviceID.data, Data(name.utf8))
        }
    }
}

// MARK: - Sessione cifrata

/// Lato che invia: numera i pacchetti e li sigilla.
struct Sealer {
    let key: SymmetricKey
    let sessionID: UInt32
    private(set) var counter: UInt64 = 0

    init(key: SymmetricKey, sessionID: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        self.key = key
        self.sessionID = sessionID
    }

    mutating func seal(_ plaintext: Data, senderID: UUID) -> Data? {
        counter += 1
        var nonce = Data()
        nonce.append(contentsOf: withUnsafeBytes(of: sessionID.bigEndian) { Array($0) })
        nonce.append(contentsOf: withUnsafeBytes(of: counter.bigEndian) { Array($0) })
        guard let n = try? ChaChaPoly.Nonce(data: nonce),
              let box = try? ChaChaPoly.seal(plaintext, using: key, nonce: n, authenticating: senderID.data) else { return nil }
        var body = senderID.data
        body.append(box.combined)
        return Wire.frame(.data, body)
    }
}

/// Lato che riceve: apre i pacchetti e rifiuta i replay.
struct Opener {
    let key: SymmetricKey
    private(set) var lastSession: UInt32 = 0
    private(set) var lastCounter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    enum Failure: Error { case malformed, replay, badTag }

    /// `body` = quello che segue l'header di un pacchetto `.data`: peerID(16) + box.
    mutating func open(_ body: Data) throws -> (senderID: UUID, plaintext: Data) {
        let b = Data(body)
        guard b.count > 16 + 12 + 16, let sender = UUID(data: b.prefix(16)) else { throw Failure.malformed }
        let combined = b.dropFirst(16)
        guard let box = try? ChaChaPoly.SealedBox(combined: combined) else { throw Failure.malformed }
        let nonce = Data(box.nonce)
        let session = nonce.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let counter = nonce.dropFirst(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        if session == lastSession && counter <= lastCounter { throw Failure.replay }
        guard let plain = try? ChaChaPoly.open(box, using: key, authenticating: sender.data) else { throw Failure.badTag }
        lastSession = session
        lastCounter = counter
        return (sender, plain)
    }
}

// MARK: - Utilita'

extension UUID {
    var data: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
