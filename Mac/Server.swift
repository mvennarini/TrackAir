import Foundation
import CoreGraphics
import Network
import os
import CryptoKit

let log = Logger(subsystem: "trackair", category: "server")

/// Stato di un dispositivo collegato.
struct ConnectedDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var since: Date
}

/// Ascolta i datagrammi UDP, gestisce abbinamento e sessioni cifrate,
/// traduce i messaggi in eventi mouse.
final class Server: ObservableObject {
    @Published var status = String(localized: "Starting…")
    @Published var connected: [ConnectedDevice] = []
    @Published var peers: [PeerRecord] = []

    let store: PeerStore
    let pairing = PairingController()
    private(set) var web: WebServer?
    private(set) var ble: BLEServer?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "trackair.server")
    private let mouse = MouseController()
    private var reaper: DispatchSourceTimer?

    private struct Flow {
        let conn: NWConnection
        var peerID: UUID?
        var opener: Opener?
        var sealer: Sealer?
        var lastSeen: Date
    }
    private var flows: [ObjectIdentifier: Flow] = [:]

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrackAir", isDirectory: true)
        store = PeerStore(directory: dir)
        peers = store.peers
        start()
        web = WebServer(server: self)
        ble = BLEServer(server: self)
    }

    // MARK: rete

    /// Interfaccia con cui il Mac parla con la rete di casa. Senza questo vincolo
    /// Bonjour annuncia anche i bridge delle macchine virtuali (192.168.x.1 e simili)
    /// e l'iPhone puo' scegliere un indirizzo irraggiungibile.
    static func primaryInterface() -> NWInterface? {
        let monitor = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        var found: NWInterface?
        monitor.pathUpdateHandler = { path in
            found = path.availableInterfaces.first { $0.type == .wifi || $0.type == .wiredEthernet }
            sem.signal()
        }
        monitor.start(queue: DispatchQueue(label: "trackair.iface"))
        _ = sem.wait(timeout: .now() + 2)
        monitor.cancel()
        return found
    }

    func start() {
        let params = NWParameters.udp
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVoice
        if let iface = Self.primaryInterface() {
            params.requiredInterface = iface
            log.notice("interfaccia: \(iface.name, privacy: .public)")
        }
        do { listener = try NWListener(using: params) } catch {
            status = String(localized: "Error: \(error.localizedDescription)"); return
        }
        var txt = NWTXTRecord()
        txt["id"] = LocalIdentity.id.uuidString
        txt["v"] = "\(Wire.version)"
        listener?.service = NWListener.Service(name: Host.current().localizedName ?? "Mac",
                                               type: Msg.serviceType, txtRecord: txt)
        listener?.stateUpdateHandler = { [weak self] st in
            DispatchQueue.main.async {
                switch st {
                case .ready:
                    self?.status = String(localized: "Ready")
                    log.notice("in ascolto porta \(self?.listener?.port?.rawValue ?? 0)")
                case .failed(let e): self?.status = String(localized: "Error: \(e.localizedDescription)")
                case .cancelled: self?.status = String(localized: "Stopped")
                default: break
                }
            }
        }
        listener?.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener?.start(queue: queue)

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.reap() }
        t.resume()
        reaper = t
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        flows[id] = Flow(conn: conn, peerID: nil, opener: nil, sealer: nil, lastSeen: Date())
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.drop(id) }
            if case .cancelled = st { self?.drop(id) }
        }
        conn.start(queue: queue)
        receive(conn)
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            let id = ObjectIdentifier(conn)
            if let data { self.handle(data, flowID: id) }
            if error == nil { self.receive(conn) } else { self.drop(id) }
        }
    }

    private func send(_ data: Data, to id: ObjectIdentifier) {
        flows[id]?.conn.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: protocollo

    private func handle(_ data: Data, flowID id: ObjectIdentifier) {
        guard let (kind, body) = Wire.parse(data) else { return }
        flows[id]?.lastSeen = Date()
        switch kind {
        case .data:        handleData(body, flowID: id)
        case .pairRequest: handlePairRequest(body, flowID: id)
        case .pairKnock:
            knock(String(decoding: body.dropFirst(16), as: UTF8.self))
        default: break
        }
    }

    private func handleData(_ body: Data, flowID id: ObjectIdentifier) {
        guard var flow = flows[id] else { return }
        let b = Data(body)
        guard b.count >= 16, let sender = UUID(data: b.prefix(16)) else { return }

        if flow.opener == nil || flow.peerID != sender {
            guard let peer = store.peer(sender) else {
                // dispositivo sconosciuto: chiedi l'abbinamento
                send(Wire.frame(.needPairing, LocalIdentity.id.data), to: id)
                return
            }
            flow.peerID = sender
            flow.opener = Opener(key: SymmetricKey(data: peer.receiveKey))
            flow.sealer = Sealer(key: SymmetricKey(data: peer.sendKey))
        }
        do {
            let (_, plain) = try flow.opener!.open(body)
            flows[id] = flow
            guard let msg = Msg.decode(plain) else { return }
            dispatch(msg, flowID: id, peerID: sender)
        } catch Opener.Failure.replay {
            return
        } catch {
            // chiave sbagliata (il dispositivo ha perso o rifatto l'abbinamento)
            flows[id]?.opener = nil
            send(Wire.frame(.needPairing, LocalIdentity.id.data), to: id)
        }
    }

    /// Esegue un messaggio gia' decifrato. `ack` manda la risposta cifrata (hello) al mittente.
    func perform(_ m: Msg, peerID: UUID, ack: (Msg) -> Void) {
        switch m.type {
        case .move:        mouse.move(dx: CGFloat(m.a), dy: CGFloat(m.b))
        case .scroll:      mouse.scroll(dx: CGFloat(m.a), dy: CGFloat(m.b))
        case .scrollEnd:   mouse.scrollEnd()
        case .momentum:    mouse.momentum(dx: CGFloat(m.a), dy: CGFloat(m.b))
        case .momentumEnd: mouse.momentumEnd()
        case .button:      mouse.button(Int(m.a), down: m.b > 0.5)
        case .key:         mouse.key(CGKeyCode(m.a), mods: Int(m.b))
        case .action:      SystemActions.perform(m.a)
        case .text:        if let t = m.name { mouse.type(t) }
        case .hello:
            let name = m.name ?? store.peer(peerID)?.name ?? "?"
            markConnected(peerID, name: name)
            ack(Msg(type: .hello, name: Host.current().localizedName ?? "Mac"))
        }
    }

    private func dispatch(_ m: Msg, flowID id: ObjectIdentifier, peerID: UUID) {
        perform(m, peerID: peerID) { reply in
            if var s = flows[id]?.sealer, let d = s.seal(reply.encode(), senderID: LocalIdentity.id) {
                flows[id]?.sealer = s
                send(d, to: id)
            }
        }
    }

    /// Valuta una richiesta di abbinamento (da qualunque canale) e restituisce il frame di risposta.
    func pair(_ req: Pairing.Request) -> Data {
        switch pairing.evaluate(req) {
        case .accepted(let pin):
            let priv = Curve25519.KeyAgreement.PrivateKey()
            guard let theirPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: req.publicKey),
                  let shared = try? priv.sharedSecretFromKeyAgreement(with: theirPub) else {
                return Wire.frame(.pairFailed, Data("bad-key".utf8))
            }
            let keys = Pairing.deriveKeys(shared: shared, deviceID: req.deviceID, macID: LocalIdentity.id)
            store.upsert(PeerRecord(id: req.deviceID, name: req.name,
                                    sendKey: keys.macToDevice.withUnsafeBytes { Data($0) },
                                    receiveKey: keys.deviceToMac.withUnsafeBytes { Data($0) },
                                    pairedAt: Date(), lastSeen: nil))
            log.notice("abbinato \(req.name, privacy: .public)")
            DispatchQueue.main.async {
                self.peers = self.store.peers
                self.pairing.finish(success: true, name: req.name)
            }
            return Pairing.Response.make(macID: LocalIdentity.id, name: Host.current().localizedName ?? "Mac",
                                         deviceID: req.deviceID, pin: pin, privateKey: priv)
        case .wrongPIN: return Wire.frame(.pairFailed, Data("wrong-pin".utf8))
        case .locked:   return Wire.frame(.pairFailed, Data("locked".utf8))
        case .notPairing:
            DispatchQueue.main.async { self.pairing.begin(requestFrom: req.name) }
            return Wire.frame(.pairFailed, Data("show-pin".utf8))
        }
    }

    func knock(_ name: String) {
        DispatchQueue.main.async { if !self.pairing.active { self.pairing.begin(requestFrom: name) } }
    }

    func markConnectedExternal(_ id: UUID, name: String) { markConnected(id, name: name) }
    func dropExternal(_ id: UUID) { DispatchQueue.main.async { self.connected.removeAll { $0.id == id } } }

    private func handlePairRequest(_ body: Data, flowID id: ObjectIdentifier) {
        guard let req = Pairing.Request.parse(body) else { return }
        let reply = pair(req)
        flows[id]?.opener = nil
        send(reply, to: id)
    }

    // MARK: stato

    private func markConnected(_ id: UUID, name: String) {
        store.touch(id)
        DispatchQueue.main.async {
            if let i = self.connected.firstIndex(where: { $0.id == id }) {
                self.connected[i].name = name
            } else {
                self.connected.append(ConnectedDevice(id: id, name: name, since: Date()))
                log.notice("collegato \(name, privacy: .public)")
            }
            self.peers = self.store.peers
        }
    }

    private func reap() {
        let now = Date()
        for (id, f) in flows where now.timeIntervalSince(f.lastSeen) > 8 {
            f.conn.cancel()
            flows.removeValue(forKey: id)
        }
        let alive = Set(flows.values.compactMap(\.peerID))
        DispatchQueue.main.async { self.connected.removeAll { !alive.contains($0.id) } }
    }

    private func drop(_ id: ObjectIdentifier) {
        flows.removeValue(forKey: id)
        let alive = Set(flows.values.compactMap(\.peerID))
        DispatchQueue.main.async { self.connected.removeAll { !alive.contains($0.id) } }
    }

    func forget(_ id: UUID) {
        store.remove(id)
        for (k, f) in flows where f.peerID == id { f.conn.cancel(); flows.removeValue(forKey: k) }
        DispatchQueue.main.async {
            self.peers = self.store.peers
            self.connected.removeAll { $0.id == id }
        }
    }
}
