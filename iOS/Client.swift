import Foundation
import Network
import UIKit
import CryptoKit
import CoreBluetooth

/// Come si raggiunge un Mac: via rete (Bonjour + UDP) o via Bluetooth LE.
enum Link: Equatable {
    case wifi(NWEndpoint)
    case ble(CBPeripheral)
    var label: String {
        switch self { case .wifi: return "Wi-Fi"; case .ble: return "Bluetooth" }
    }
}

struct MacInfo: Identifiable, Equatable {
    var id: String
    var macID: UUID?
    var name: String
    var link: Link
}

/// Preferenza di collegamento (Impostazioni).
enum TransportMode: String { case auto, wifi, bluetooth }

/// Trova i Mac (Bonjour e Bluetooth), gestisce abbinamento e sessione cifrata, manda i gesti.
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
    @Published var connectingSince = Date.distantPast
    @Published var linkLabel: String = ""
    @Published var bluetoothAvailable = false
    var bluetoothState: String { ble.stateText }

    let store: PeerStore
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let ble = BLEClient()
    private var keepalive: Timer?
    private var current: MacInfo?
    private var sealer: Sealer?
    private var opener: Opener?
    private var pendingPair: (pin: String, priv: Curve25519.KeyAgreement.PrivateKey)?
    private var lastAck = Date.distantPast
    private var connectedSince = Date.distantPast
    private var lastHello = Date.distantPast
    private var wifiFailures = 0
    private let queue = DispatchQueue(label: "trackair.client")
    private let lastMacKey = "trackair.lastMac"

    var mode: TransportMode { TransportMode(rawValue: UserDefaults.standard.string(forKey: "transport") ?? "auto") ?? .auto }
    var keepWifiAwake: Bool { UserDefaults.standard.object(forKey: "keepWifiAwake") == nil ? true : UserDefaults.standard.bool(forKey: "keepWifiAwake") }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackAir", isDirectory: true)
        store = PeerStore(directory: dir)
        peers = store.peers
        wireBLE()
    }

    var isConnected: Bool { if case .connected = state { return true }; return false }
    var currentName: String? { current?.name }
    var stalled: Bool {
        if case .connecting = state { return Date().timeIntervalSince(connectingSince) > 5 }
        return false
    }

    // MARK: ricerca

    func startBrowsing() {
        browser?.cancel(); browser = nil
        found.removeAll { if case .wifi = $0.link { return true }; return false }
        if mode != .bluetooth {
            let params = NWParameters.udp
            params.includePeerToPeer = true
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: Msg.serviceType, domain: nil), using: params)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                DispatchQueue.main.async { self?.updateWifi(results) }
            }
            b.start(queue: queue)
            browser = b
        }
        if mode != .wifi { ble.startScan() } else { ble.stopScan() }
        pickIfIdle()
    }

    func stop() {
        keepalive?.invalidate(); keepalive = nil
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        ble.stopScan(); ble.disconnect()
        sealer = nil; opener = nil; current = nil
        state = .searching; linkLabel = ""
    }

    private func updateWifi(_ results: Set<NWBrowser.Result>) {
        found.removeAll { if case .wifi = $0.link { return true }; return false }
        for r in results {
            var id: UUID? = nil
            if case .bonjour(let txt) = r.metadata, let s = txt["id"] { id = UUID(uuidString: s) }
            found.append(MacInfo(id: "wifi:\(r.endpoint)", macID: id, name: Self.name(of: r), link: .wifi(r.endpoint)))
        }
        found.sort { $0.name < $1.name }
        if let cur = current, case .wifi = cur.link, !found.contains(where: { $0.id == cur.id }) {
            disconnect(keepState: false)
        }
        pickIfIdle()
    }

    private func wireBLE() {
        ble.onAvailability = { [weak self] ok in self?.bluetoothAvailable = ok }
        ble.onFound = { [weak self] p, name in
            guard let self else { return }
            let info = MacInfo(id: "ble:\(p.identifier.uuidString)", macID: nil, name: name, link: .ble(p))
            if !self.found.contains(where: { $0.id == info.id }) { self.found.append(info); self.found.sort { $0.name < $1.name } }
            self.pickIfIdle()
        }
        ble.onLost = { [weak self] p in self?.found.removeAll { $0.id == "ble:\(p.identifier.uuidString)" } }
        ble.onReady = { [weak self] p, macID, name in
            guard let self, let cur = self.current, case .ble(let cp) = cur.link, cp === p else { return }
            self.current?.macID = macID
            self.current?.name = name
            if let i = self.found.firstIndex(where: { $0.id == cur.id }) { self.found[i].macID = macID; self.found[i].name = name }
            self.onReady()
        }
        ble.onReceive = { [weak self] d in self?.handle(d) }
        ble.onDisconnect = { [weak self] p in
            guard let self, let cur = self.current, case .ble(let cp) = cur.link, cp === p else { return }
            self.disconnect(keepState: false)
            self.pickIfIdle()
        }
    }

    private func pickIfIdle() {
        guard connection == nil, ble.peripheral == nil, let pick = chooseMac() else { return }
        connect(to: pick)
    }

    /// Preferenza: ultimo Mac usato, poi un Mac abbinato, poi il primo trovato.
    /// In automatico il Wi-Fi vince sul Bluetooth, a meno che abbia appena fallito.
    private func chooseMac() -> MacInfo? {
        var candidates = found
        switch mode {
        case .wifi: candidates = candidates.filter { if case .wifi = $0.link { return true }; return false }
        case .bluetooth: candidates = candidates.filter { if case .ble = $0.link { return true }; return false }
        case .auto:
            let preferBLE = wifiFailures >= 1
            candidates.sort { a, b in
                let aw: Bool = { if case .wifi = a.link { return true }; return false }()
                let bw: Bool = { if case .wifi = b.link { return true }; return false }()
                return preferBLE ? (!aw && bw) : (aw && !bw)
            }
        }
        if let last = UserDefaults.standard.string(forKey: lastMacKey),
           let m = candidates.first(where: { $0.macID?.uuidString == last }) { return m }
        if let m = candidates.first(where: { mac in mac.macID.map { store.peer($0) != nil } ?? false }) { return m }
        return candidates.first
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
        linkLabel = mac.link.label
        connectingSince = Date()
        switch mac.link {
        case .wifi(let endpoint):
            let params = NWParameters.udp
            params.prohibitedInterfaceTypes = [.cellular]
            params.serviceClass = .interactiveVoice
            let c = NWConnection(to: endpoint, using: params)
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
        case .ble(let p):
            ble.connect(p)   // onReady arriva dopo la lettura dell'identita'
        }
        keepalive = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func disconnect(keepState: Bool) {
        keepalive?.invalidate(); keepalive = nil
        connection?.cancel(); connection = nil
        ble.disconnect()
        sealer = nil; opener = nil; pendingPair = nil
        current = nil
        if !keepState { state = .searching; showPINEntry = false; linkLabel = "" }
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

    /// 20 volte al secondo: keep-alive fitto che tiene sveglia la radio Wi-Fi
    /// (se attivo), riconnessione se il Mac tace, ricalcolo di "stalled".
    private func tick() {
        guard current != nil else { return }
        objectWillChange.send()
        let now = Date()
        if case .connected = state, now.timeIntervalSince(lastAck) > 6 {
            if case .wifi = current!.link { wifiFailures += 1 }
            let mac = current!
            disconnect(keepState: true)
            if mode == .auto, wifiFailures >= 1, let b = found.first(where: { if case .ble = $0.link { return $0.macID == mac.macID || mac.macID == nil }; return false }) {
                connect(to: b)
            } else {
                connect(to: mac)
            }
            return
        }
        if case .connecting = state, stalled, mode == .auto, case .wifi = current!.link,
           let b = found.first(where: { if case .ble = $0.link { return true }; return false }) {
            // il Mac non risponde via rete: provo il Bluetooth
            wifiFailures += 1
            connect(to: b)
            return
        }
        guard sealer != nil else { return }
        let interval: TimeInterval
        if case .wifi = current!.link, keepWifiAwake, isConnected { interval = 0.05 } else { interval = 2 }
        if now.timeIntervalSince(lastHello) >= interval { sendHello() }
    }

    private func sendHello() {
        lastHello = Date()
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
                    if case .wifi = mac.link { wifiFailures = 0 }
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
            default:          pairingError = nil
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

    func retry() {
        wifiFailures = 0
        disconnect(keepState: false)
        startBrowsing()
    }

    func repair() {
        if let id = current?.macID { store.remove(id); peers = store.peers }
        sealer = nil; opener = nil
        if current != nil { beginPairing() } else { retry() }
    }

    func knock() {
        var body = LocalIdentity.id.data
        body.append(Data(UIDevice.current.name.utf8))
        sendRaw(Wire.frame(.pairKnock, body))
    }

    func submitCode(_ text: String) -> Bool {
        guard let code = Pairing.parseCode(text) else { return false }
        if current != nil && current?.macID == nil { current?.macID = code.macID }
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
        guard pin.count >= Pairing.pinLength, current != nil else { return }
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
        store.upsert(PeerRecord(id: resp.macID, name: resp.name,
                                sendKey: keys.deviceToMac.withUnsafeBytes { Data($0) },
                                receiveKey: keys.macToDevice.withUnsafeBytes { Data($0) },
                                pairedAt: Date(), lastSeen: Date()))
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
        if current?.macID == id { disconnect(keepState: false); pickIfIdle() }
    }

    // MARK: invio

    private func sendRaw(_ d: Data) {
        guard let cur = current else { return }
        switch cur.link {
        case .wifi: connection?.send(content: d, completion: .contentProcessed { _ in })
        case .ble: ble.send(d)
        }
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
