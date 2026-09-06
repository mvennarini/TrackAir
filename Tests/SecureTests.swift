import XCTest
import CryptoKit
@testable import TrackAir

final class SecureTests: XCTestCase {

    func testMessageRoundTrip() {
        let m = Msg(type: .move, a: 12.5, b: -3.25)
        let d = Msg.decode(m.encode())
        XCTAssertEqual(d?.type, .move); XCTAssertEqual(d?.a, 12.5); XCTAssertEqual(d?.b, -3.25)
        let h = Msg.decode(Msg(type: .hello, name: "iPhone di Michele").encode())
        XCTAssertEqual(h?.name, "iPhone di Michele")
    }

    func testWireFrame() {
        let f = Wire.frame(.needPairing, Data([1, 2, 3]))
        let p = Wire.parse(f)
        XCTAssertEqual(p?.kind, .needPairing); XCTAssertEqual(Array(p!.body), [1, 2, 3])
        XCTAssertNil(Wire.parse(Data([0x54, 1, 1])))      // versione vecchia
        XCTAssertNil(Wire.parse(Data([0x00, 2, 1])))      // magic sbagliato
    }

    func testSealOpenAndReplay() throws {
        let key = SymmetricKey(size: .bits256)
        let sender = UUID()
        var sealer = Sealer(key: key)
        var opener = Opener(key: key)
        let p1 = sealer.seal(Data("uno".utf8), senderID: sender)!
        let p2 = sealer.seal(Data("due".utf8), senderID: sender)!
        let b1 = Wire.parse(p1)!.body, b2 = Wire.parse(p2)!.body
        XCTAssertEqual(try opener.open(b1).plaintext, Data("uno".utf8))
        XCTAssertEqual(try opener.open(b2).plaintext, Data("due".utf8))
        XCTAssertThrowsError(try opener.open(b1)) { XCTAssertEqual($0 as? Opener.Failure, .replay) }
        XCTAssertThrowsError(try opener.open(b2)) { XCTAssertEqual($0 as? Opener.Failure, .replay) }
    }

    func testTamperedPacketIsRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var sealer = Sealer(key: key)
        var opener = Opener(key: key)
        var body = Data(Wire.parse(sealer.seal(Data("ciao".utf8), senderID: UUID())!)!.body)
        body[body.count - 1] ^= 0xFF
        XCTAssertThrowsError(try opener.open(body)) { XCTAssertEqual($0 as? Opener.Failure, .badTag) }
    }

    func testWrongKeyIsRejected() throws {
        var sealer = Sealer(key: SymmetricKey(size: .bits256))
        var opener = Opener(key: SymmetricKey(size: .bits256))
        let body = Wire.parse(sealer.seal(Data("x".utf8), senderID: UUID())!)!.body
        XCTAssertThrowsError(try opener.open(body))
    }

    func testPairingHandshake() throws {
        let pin = Pairing.randomPIN()
        XCTAssertEqual(pin.count, 6)
        let deviceID = UUID(), macID = UUID()
        let devPriv = Curve25519.KeyAgreement.PrivateKey()
        let reqFrame = Pairing.Request.make(deviceID: deviceID, name: "iPad", pin: pin, privateKey: devPriv)
        let req = Pairing.Request.parse(Wire.parse(reqFrame)!.body)!
        XCTAssertTrue(req.isValid(pin: pin))
        XCTAssertFalse(req.isValid(pin: "000000"))
        XCTAssertEqual(req.name, "iPad")

        let macPriv = Curve25519.KeyAgreement.PrivateKey()
        let respFrame = Pairing.Response.make(macID: macID, name: "Mac", deviceID: deviceID, pin: pin, privateKey: macPriv)
        let resp = Pairing.Response.parse(Wire.parse(respFrame)!.body)!
        XCTAssertTrue(resp.isValid(pin: pin, deviceID: deviceID))
        XCTAssertFalse(resp.isValid(pin: pin, deviceID: UUID()))

        // entrambi derivano le stesse chiavi
        let sharedMac = try macPriv.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: req.publicKey))
        let sharedDev = try devPriv.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: resp.publicKey))
        let kMac = Pairing.deriveKeys(shared: sharedMac, deviceID: deviceID, macID: macID)
        let kDev = Pairing.deriveKeys(shared: sharedDev, deviceID: deviceID, macID: macID)
        XCTAssertEqual(kMac.deviceToMac, kDev.deviceToMac)
        XCTAssertEqual(kMac.macToDevice, kDev.macToDevice)
        XCTAssertNotEqual(kMac.deviceToMac, kMac.macToDevice)

        // e i pacchetti del dispositivo si aprono sul Mac
        var s = Sealer(key: kDev.deviceToMac)
        var o = Opener(key: kMac.deviceToMac)
        let body = Wire.parse(s.seal(Msg(type: .button, a: 0, b: 1).encode(), senderID: deviceID)!)!.body
        let opened = try o.open(body)
        XCTAssertEqual(opened.senderID, deviceID)
        XCTAssertEqual(Msg.decode(opened.plaintext)?.type, .button)
    }

    func testPeerStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tocco-test-\(UUID().uuidString)")
        let store = PeerStore(directory: dir)
        let p = PeerRecord(id: UUID(), name: "iPhone", sendKey: Data(repeating: 1, count: 32),
                           receiveKey: Data(repeating: 2, count: 32), pairedAt: Date(), lastSeen: nil)
        store.upsert(p)
        XCTAssertEqual(PeerStore(directory: dir).peer(p.id)?.name, "iPhone")
        store.remove(p.id)
        XCTAssertNil(PeerStore(directory: dir).peer(p.id))
        try? FileManager.default.removeItem(at: dir)
    }
}
