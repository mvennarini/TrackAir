import Foundation
import CoreBluetooth
import CryptoKit
import os

private let blog = Logger(subsystem: "trackair", category: "ble")

/// Periferica Bluetooth LE: stesso protocollo del canale UDP, un flusso per centrale.
final class BLEServer: NSObject, CBPeripheralManagerDelegate, ObservableObject {
    @Published var status: String = "…"
    private weak var server: Server?
    private var pm: CBPeripheralManager!
    private let queue = DispatchQueue(label: "trackair.ble")
    private var tx: CBMutableCharacteristic!
    private var rxUUID = CBUUID(string: BLE.rx), infoUUID = CBUUID(string: BLE.info)

    private final class Flow {
        let central: CBCentral
        var peerID: UUID?
        var opener: Opener?
        var sealer: Sealer?
        let assembler = BLE.Assembler()
        var outbox: [Data] = []
        var chunkID: UInt8 = 0
        init(central: CBCentral) { self.central = central }
    }
    private var flows: [UUID: Flow] = [:]

    init(server: Server) {
        self.server = server
        super.init()
        pm = CBPeripheralManager(delegate: self, queue: queue, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
    }

    var isAdvertising: Bool { pm.isAdvertising }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        let states: [CBManagerState: String] = [.poweredOff: "off", .unauthorized: "unauthorized", .unsupported: "unsupported", .resetting: "resetting", .unknown: "unknown"]
        guard p.state == .poweredOn else {
            let name = states[p.state] ?? "?"
            blog.notice("bluetooth: \(name, privacy: .public)")
            DispatchQueue.main.async { self.status = name }
            return
        }
        let service = CBMutableService(type: CBUUID(string: BLE.service), primary: true)
        let rx = CBMutableCharacteristic(type: rxUUID, properties: [.writeWithoutResponse, .write], value: nil, permissions: [.writeable])
        tx = CBMutableCharacteristic(type: CBUUID(string: BLE.tx), properties: [.notify], value: nil, permissions: [.readable])
        var infoData = LocalIdentity.id.data
        infoData.append(Data((Host.current().localizedName ?? "Mac").utf8))
        let info = CBMutableCharacteristic(type: infoUUID, properties: [.read], value: infoData, permissions: [.readable])
        service.characteristics = [rx, tx, info]
        p.add(service)
        p.startAdvertising([CBAdvertisementDataLocalNameKey: Host.current().localizedName ?? "Mac",
                            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BLE.service)]])
        blog.notice("bluetooth: servizio aggiunto, avvio pubblicazione")
    }

    func peripheralManager(_ p: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { blog.error("bluetooth: servizio non aggiunto: \(error.localizedDescription, privacy: .public)"); DispatchQueue.main.async { self.status = "service error" } }
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error {
            blog.error("bluetooth: pubblicazione fallita: \(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { self.status = "error: \(error.localizedDescription)" }
        } else {
            blog.notice("bluetooth: in pubblicazione")
            DispatchQueue.main.async { self.status = "advertising" }
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        flows[central.identifier] = Flow(central: central)
        blog.notice("bluetooth: centrale collegata")
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        if let f = flows.removeValue(forKey: central.identifier), let id = f.peerID { server?.dropExternal(id) }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            guard r.characteristic.uuid == rxUUID, let d = r.value else { continue }
            let flow = flows[r.central.identifier] ?? { let f = Flow(central: r.central); flows[r.central.identifier] = f; return f }()
            if let frame = flow.assembler.feed(d) { handle(frame, flow: flow) }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) {
        for f in flows.values { flush(f) }
    }

    // MARK: protocollo

    private func send(_ data: Data, to flow: Flow) {
        flow.chunkID &+= 1
        flow.outbox += BLE.split(data, max: flow.central.maximumUpdateValueLength, id: flow.chunkID)
        flush(flow)
    }

    private func flush(_ flow: Flow) {
        while let next = flow.outbox.first {
            guard pm.updateValue(next, for: tx, onSubscribedCentrals: [flow.central]) else { return }   // riprova su isReady
            flow.outbox.removeFirst()
        }
    }

    private func handle(_ data: Data, flow: Flow) {
        guard let server, let (kind, body) = Wire.parse(data) else { return }
        switch kind {
        case .pairKnock:
            server.knock(String(decoding: body.dropFirst(16), as: UTF8.self))
        case .pairRequest:
            guard let req = Pairing.Request.parse(body) else { return }
            flow.opener = nil
            send(server.pair(req), to: flow)
        case .data:
            let b = Data(body)
            guard b.count >= 16, let sender = UUID(data: b.prefix(16)) else { return }
            if flow.opener == nil || flow.peerID != sender {
                guard let peer = server.store.peer(sender) else {
                    send(Wire.frame(.needPairing, LocalIdentity.id.data), to: flow); return
                }
                flow.peerID = sender
                flow.opener = Opener(key: SymmetricKey(data: peer.receiveKey))
                flow.sealer = Sealer(key: SymmetricKey(data: peer.sendKey))
            }
            do {
                let (_, plain) = try flow.opener!.open(body)
                guard let msg = Msg.decode(plain) else { return }
                server.perform(msg, peerID: sender) { reply in
                    if let d = flow.sealer?.seal(reply.encode(), senderID: LocalIdentity.id) { send(d, to: flow) }
                }
            } catch Opener.Failure.replay {
                return
            } catch {
                flow.opener = nil
                send(Wire.frame(.needPairing, LocalIdentity.id.data), to: flow)
            }
        default: break
        }
    }
}
