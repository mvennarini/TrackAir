import Foundation
import Network
import UIKit
import CryptoKit

struct MacInfo: Identifiable, Equatable {
    var id: String { "\(endpoint)" }
    var macID: UUID?
    var name: String
    var endpoint: NWEndpoint
}

/// Trova i Mac via Bonjour, gestisce abbinamento e sessione cifrata, manda i gesti.
final class Client: ObservableObject {
    enum State: Equatable {
        case searching
        case connecting(String)
        case pairing(String)
        case connected(String)
    }

    @Published var state: State = .searching
    @Published var found: [MacInfo] = []
    @Published var showPINEntry = false
    @Published var pairingError: String? = nil
    @Published var peers: [PeerRecord] = []

    let store: PeerStore
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var keepalive: Timer?
    private var current: MacInfo?
    private var sealer: Sealer?
    private var opener: Opener?
    private var pendingPair: (pin: String, priv: Curve25519.KeyAgreement.PrivateKey)?
    private var lastAck = Date.distantPast
    private var connectedSince = Date.distantPast
    @Published var connectingSince = Date.distantPast
    /// Vero se stiamo aspettando il Mac da troppo: il collegamento c'e' ma non risponde.
    var stalled: Bool {
        if case .connecting = state { return Date().timeIntervalSince(connectingSince) > 5 }
        return false
    }
    private let queue = DispatchQueue(label: "trackair.client")
    private let lastMacKey = "trackair.lastMac"

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackAir", isDirectory: true)
        store = PeerStore(directory: dir)
        peers = store.peers
    }

    var isConnected: Bool { if case .connected = state { return true }; return false }
    var currentName: String? { current?.name }

    // MARK: ricerca

    func startBrowsing() {
        browser?.cancel()
        let params = NWParameters.udp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Msg.serviceType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.updateFound(results) }
        }
        b.start(queue: queue)
        browser = b
    }

    func stop() {
        keepalive?.invalidate(); keepalive = nil
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        sealer = nil; opener = nil; current = nil
        state = .searching
    }

    private func updateFound(_ results: Set<NWBrowser.Result>) {
        found = results.map { r in
            var id: UUID? = nil
            if case .bonjour(let txt) = r.metadata, let s = txt["id"] { id = UUID(uuidString: s) }
            return MacInfo(macID: id, name: Self.name(of: r), endpoint: r.endpoint)
        }.sorted { $0.name < $1.name }

        if let cur = current, !found.contains(where: { $0.endpoint == cur.endpoint }) {
            disconnect(keepState: false)
        }
        if connection == nil, let pick = chooseMac() { connect(to: pick) }
    }

    /// Preferisce l'ultimo Mac usato, poi un Mac gia' abbinato, poi il primo trovato.
    private func chooseMac() -> MacInfo? {
        if let last = UserDefaults.standard.string(forKey: lastMacKey),
           let m = found.first(where: { $0.macID?.uuidString == last }) { return m }
        if let m = found.first(where: { mac in mac.macID.map { store.peer($0) != nil } ?? false }) { return m }
        return found.first
    }

    static func name(of r: NWBrowser.Result) -> String {
        if case let .service(name, _, _, _) = r.endpoint { return name }
        return "\(r.endpoint)"
    }

    // MARK: connessione

    func connect(to mac: MacInfo) {
        disconnect(keepState: true)
        current = mac
        state = .connecting(mac.name)
        let params = NWParameters.udp
        params.prohibitedInterfaceTypes = [.cellular]
        let c = NWConnection(to: mac.endpoint, using: params)
        connectingSince = Date()
        c.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                guard let self else { return }
                switch st {
                case .ready: self.onReady()
                case .failed, .cancelled: if self.connection === c { self.disconnect(keepState: false) }
                default: break
                }
            }
        }
        c.start(queue: queue)
        connection = c
        receive(c)
        keepalive = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func disconnect(keepState: Bool) {
        keepalive?.invalidate(); keepalive = nil
        connection?.cancel(); connection = nil
        sealer = nil; opener = nil; pendingPair = nil
        current = nil
        if !keepState { state = .searching; showPINEntry = false }
    }

    private func onReady() {
        guard let mac = current else { return }
        if let id = mac.macID, let peer = store.peer(id) {
            sealer = Sealer(key: SymmetricKey(data: peer.sendKey))
            opener = Opener(key: SymmetricKey(data: peer.receiveKey))
            sendHello()
        } else {
            beginPairing()
        }
    }

    private func tick() {
        guard connection != nil else { return }
        objectWillChange.send()   // aggiorna "stalled" nella UI
        if case .connected = state, Date().timeIntervalSince(lastAck) > 6 {
            // il Mac non risponde piu': riprova da capo
            state = current.map { .connecting($0.name) } ?? .searching
            if let mac = current { connect(to: mac) }
            return
        }
        if sealer != nil { sendHello() }
    }

    private func sendHello() {
        sendSealed(Msg(type: .hello, name: UIDevice.current.name))
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === c else { return }
            if let data { DispatchQueue.main.async { self.handle(data) } }
            if error == nil { self.receive(c) }
        }
    }

    private func handle(_ data: Data) {
        guard let (kind, body) = Wire.parse(data) else { return }
        switch kind {
        case .data:
            guard opener != nil, let (_, plain) = try? opener!.open(body),
                  let msg = Msg.decode(plain), msg.type == .hello else { return }
            lastAck = Date()
            if case .connected = state {} else {
                if let mac = current {
                    state = .connected(msg.name ?? mac.name)
                    connectedSince = Date()
                    if let id = mac.macID { UserDefaults.standard.set(id.uuidString, forKey: lastMacKey); store.touch(id) }
                    peers = store.peers
                }
                showPINEntry = false
            }
        case .needPairing:
            if let id = current?.macID { store.remove(id); peers = store.peers }
            sealer = nil; opener = nil
            beginPairing()
        case .pairResponse:
            finishPairing(body)
        case .pairFailed:
            let reason = String(decoding: body, as: UTF8.self)
            switch reason {
            case "wrong-pin": pairingError = String(localized: "Wrong PIN. Check the number on your Mac and try again.")
            case "locked":    pairingError = String(localized: "Too many attempts. Wait 30 seconds and try again.")
            default:          pairingError = nil   // "show-pin": il Mac ha appena mostrato il PIN
            }
            pendingPair = nil
            showPINEntry = true
        default: break
        }
    }

    // MARK: abbinamento

    private func beginPairing() {
        guard let mac = current else { return }
        state = .pairing(mac.name)
        pairingError = nil
        showPINEntry = true
        knock()
    }

    /// Ricomincia da capo la ricerca e il collegamento.
    func retry() {
        disconnect(keepState: false)
        startBrowsing()
    }

    /// Forza un nuovo abbinamento con il Mac corrente (le chiavi vecchie vengono scartate).
    func repair() {
        if let id = current?.macID { store.remove(id); peers = store.peers }
        sealer = nil; opener = nil
        if connection != nil { beginPairing() } else { retry() }
    }

    /// Chiede al Mac di mostrare il PIN.
    func knock() {
        var body = LocalIdentity.id.data
        body.append(Data(UIDevice.current.name.utf8))
        sendRaw(Wire.frame(.pairKnock, body))
    }

    /// Codice letto con la fotocamera: contiene l'ID del Mac e il segreto.
    /// Se il Mac inquadrato non e' quello a cui siamo collegati, ci si collega a quello.
    func submitCode(_ text: String) -> Bool {
        guard let code = Pairing.parseCode(text) else { return false }
        if current != nil && current?.macID == nil {
            // il Mac collegato non ha ancora un ID noto: lo prendo dal codice, che e' autenticato dal segreto
            current?.macID = code.macID
        }
        if current?.macID != code.macID {
            guard let mac = found.first(where: { $0.macID == code.macID }) else {
                pairingError = String(localized: "That Mac is not on this network.")
                return false
            }
            connect(to: mac)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.submitPIN(code.secret) }
            return true
        }
        submitPIN(code.secret)
        return true
    }

    func submitPIN(_ pin: String) {
        guard pin.count >= Pairing.pinLength, connection != nil else { return }
        pairingError = nil
        let priv = Curve25519.KeyAgreement.PrivateKey()
        pendingPair = (pin, priv)
        sendRaw(Pairing.Request.make(deviceID: LocalIdentity.id, name: UIDevice.current.name, pin: pin, privateKey: priv))
    }

    private func finishPairing(_ body: Data) {
        guard let pending = pendingPair, let resp = Pairing.Response.parse(body),
              resp.isValid(pin: pending.pin, deviceID: LocalIdentity.id),
              let theirPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: resp.publicKey),
              let shared = try? pending.priv.sharedSecretFromKeyAgreement(with: theirPub) else {
            pairingError = String(localized: "Pairing failed. Try again.")
            return
        }
        let keys = Pairing.deriveKeys(shared: shared, deviceID: LocalIdentity.id, macID: resp.macID)
        let record = PeerRecord(id: resp.macID, name: resp.name,
                                sendKey: keys.deviceToMac.withUnsafeBytes { Data($0) },
                                receiveKey: keys.macToDevice.withUnsafeBytes { Data($0) },
                                pairedAt: Date(), lastSeen: Date())
        store.upsert(record)
        peers = store.peers
        current?.macID = resp.macID
        pendingPair = nil
        sealer = Sealer(key: keys.deviceToMac)
        opener = Opener(key: keys.macToDevice)
        state = .connecting(resp.name)
        sendHello()
    }

    func forget(_ id: UUID) {
        store.remove(id)
        peers = store.peers
        if current?.macID == id { disconnect(keepState: false); if let m = chooseMac() { connect(to: m) } }
    }

    // MARK: invio

    private func sendRaw(_ d: Data) {
        connection?.send(content: d, completion: .contentProcessed { _ in })
    }

    private func sendSealed(_ m: Msg) {
        guard sealer != nil, let d = sealer!.seal(m.encode(), senderID: LocalIdentity.id) else { return }
        sendRaw(d)
    }

    func send(_ m: Msg) { if isConnected { sendSealed(m) } }

    func move(dx: CGFloat, dy: CGFloat) { send(Msg(type: .move, a: Float(dx), b: Float(dy))) }
    func scroll(dx: CGFloat, dy: CGFloat) { send(Msg(type: .scroll, a: Float(dx), b: Float(dy))) }
    func scrollEnd() { send(Msg(type: .scrollEnd)) }
    func momentum(dx: CGFloat, dy: CGFloat) { send(Msg(type: .momentum, a: Float(dx), b: Float(dy))) }
    func momentumEnd() { send(Msg(type: .momentumEnd)) }
    func button(_ b: Int, down: Bool) { send(Msg(type: .button, a: Float(b), b: down ? 1 : 0)) }
    func key(_ code: Float, mods: Float) { send(Msg(type: .key, a: code, b: mods)) }
    func action(_ a: Float) { send(Msg(type: .action, a: a)) }
    func text(_ t: String) { send(Msg(type: .text, name: t)) }
}
