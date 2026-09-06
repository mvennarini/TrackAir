import Foundation
import CoreBluetooth

/// Centrale Bluetooth LE: cerca i Mac che pubblicano il servizio TrackAir,
/// si collega, legge l'identita' e scambia i frame con il Mac.
final class BLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onFound: ((CBPeripheral, String) -> Void)?
    var onLost: ((CBPeripheral) -> Void)?
    var onReady: ((CBPeripheral, UUID, String) -> Void)?    // collegato, identita' letta
    var onReceive: ((Data) -> Void)?
    var onDisconnect: ((CBPeripheral) -> Void)?
    var onAvailability: ((Bool) -> Void)?

    private var cm: CBCentralManager!
    private var wantScan = false
    private(set) var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?, tx: CBCharacteristic?
    private var assembler = BLE.Assembler()
    private var outbox: [Data] = []
    private var chunkID: UInt8 = 0
    private var lastSeen: [UUID: Date] = [:]
    private var reaper: Timer?

    var isAvailable: Bool { cm.state == .poweredOn }
    var stateText: String {
        switch cm.state {
        case .poweredOn: return cm.isScanning ? "on, scanning" : "on"
        case .poweredOff: return "off"
        case .unauthorized: return "not allowed for TrackAir (Settings → TrackAir → Bluetooth)"
        case .unsupported: return "unsupported"
        default: return "starting…"
        }
    }
    var isConnected: Bool { peripheral?.state == .connected && rx != nil }

    override init() {
        super.init()
        cm = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func startScan() {
        wantScan = true
        guard cm.state == .poweredOn, !cm.isScanning else { return }
        cm.scanForPeripherals(withServices: [CBUUID(string: BLE.service)],
                              options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        reaper?.invalidate()
        reaper = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reap() }
    }

    func stopScan() {
        wantScan = false
        if cm.state == .poweredOn { cm.stopScan() }
        reaper?.invalidate(); reaper = nil
    }

    func connect(_ p: CBPeripheral) {
        disconnect()
        peripheral = p
        p.delegate = self
        cm.connect(p, options: nil)
    }

    func disconnect() {
        if let p = peripheral { cm.cancelPeripheralConnection(p) }
        peripheral = nil; rx = nil; tx = nil
        outbox.removeAll()
        assembler = BLE.Assembler()
    }

    func send(_ data: Data) {
        guard let p = peripheral, let rx else { return }
        chunkID &+= 1
        outbox += BLE.split(data, max: p.maximumWriteValueLength(for: .withoutResponse), id: chunkID)
        flush()
    }

    private func flush() {
        guard let p = peripheral, let rx else { return }
        while let next = outbox.first {
            guard p.canSendWriteWithoutResponse else { return }   // riprende su peripheralIsReady
            p.writeValue(next, for: rx, type: .withoutResponse)
            outbox.removeFirst()
        }
    }

    private func reap() {
        let now = Date()
        for (id, t) in lastSeen where now.timeIntervalSince(t) > 8 {
            lastSeen[id] = nil
            if let p = cm.retrievePeripherals(withIdentifiers: [id]).first, p !== peripheral { onLost?(p) }
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        onAvailability?(c.state == .poweredOn)
        if c.state == .poweredOn, wantScan { startScan() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "Mac"
        let isNew = lastSeen[p.identifier] == nil
        lastSeen[p.identifier] = Date()
        if isNew { onFound?(p, name) }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([CBUUID(string: BLE.service)])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        if p === peripheral { peripheral = nil; onDisconnect?(p) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if p === peripheral { peripheral = nil; rx = nil; tx = nil; onDisconnect?(p) }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == CBUUID(string: BLE.service) }) else { return }
        p.discoverCharacteristics([CBUUID(string: BLE.rx), CBUUID(string: BLE.tx), CBUUID(string: BLE.info)], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            switch c.uuid.uuidString {
            case BLE.rx: rx = c
            case BLE.tx: tx = c; p.setNotifyValue(true, for: c)
            case BLE.info: p.readValue(for: c)
            default: break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value else { return }
        if c.uuid.uuidString == BLE.info {
            guard d.count >= 16, let id = UUID(data: d.prefix(16)) else { return }
            onReady?(p, id, String(decoding: d.dropFirst(16), as: UTF8.self))
        } else if c.uuid.uuidString == BLE.tx {
            if let frame = assembler.feed(d) { onReceive?(frame) }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { flush() }
}
