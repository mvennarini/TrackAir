import Foundation
import Network
import CryptoKit
import os

private let wlog = Logger(subsystem: "trackair", category: "web")

/// Versione web del trackpad: il Mac serve una pagina (HTTP, porta 7788) e un
/// canale WebSocket (porta 7789). Stesso protocollo cifrato dell'app nativa:
/// il browser usa la stessa crittografia (X25519, HKDF, ChaCha20-Poly1305).
final class WebServer {
    static let httpPort: UInt16 = 7788
    static let wsPort: UInt16 = 7789

    private weak var server: Server?
    private let queue = DispatchQueue(label: "trackair.web")
    private var http: NWListener?
    private var ws: NWListener?
    private var page = Data()

    private final class WSClient {
        let conn: NWConnection
        var peerID: UUID?
        var opener: Opener?
        var sealer: Sealer?
        init(conn: NWConnection) { self.conn = conn }
    }
    private var clients: [ObjectIdentifier: WSClient] = [:]

    init(server: Server) {
        self.server = server
        if let url = Bundle.main.url(forResource: "trackpad", withExtension: "html"),
           let html = try? Data(contentsOf: url) {
            page = html
        }
        startHTTP()
        startWS()
    }

    var url: String {
        let host = (Host.current().localizedName ?? "mac")
            .replacingOccurrences(of: " ", with: "-")
            .folding(options: .diacriticInsensitive, locale: nil)
        return "http://\(host).local:\(Self.httpPort)"
    }

    // MARK: HTTP (solo la pagina)

    private func startHTTP() {
        let params = NWParameters.tcp
        if let iface = Server.primaryInterface() { params.requiredInterface = iface }
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.httpPort)!) else { return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: self?.queue ?? .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                guard let self, let data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
                let line = req.split(separator: "\r\n").first ?? ""
                let parts = line.split(separator: " ")
                let path = parts.count > 1 ? String(parts[1]) : "/"
                let body: Data
                let status: String
                let type: String
                if path == "/" || path.hasPrefix("/index") || path.hasPrefix("/?") {
                    body = self.page; status = "200 OK"; type = "text/html; charset=utf-8"
                } else if path == "/config.json" {
                    let cfg = ["wsPort": Self.wsPort, "macID": LocalIdentity.id.uuidString,
                               "name": Host.current().localizedName ?? "Mac"] as [String: Any]
                    body = (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data(); status = "200 OK"; type = "application/json"
                } else {
                    body = Data("not found".utf8); status = "404 Not Found"; type = "text/plain"
                }
                var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                var out = Data(head.utf8); out.append(body); head = ""
                c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        l.stateUpdateHandler = { st in if case .failed(let e) = st { wlog.error("http: \(e.localizedDescription, privacy: .public)") } }
        l.start(queue: queue)
        http = l
    }

    // MARK: WebSocket (dati)

    private func startWS() {
        let params = NWParameters(tls: nil)
        let opts = NWProtocolWebSocket.Options()
        opts.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(opts, at: 0)
        if let iface = Server.primaryInterface() { params.requiredInterface = iface }
        guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.wsPort)!) else { return }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { st in if case .failed(let e) = st { wlog.error("ws: \(e.localizedDescription, privacy: .public)") } }
        l.start(queue: queue)
        ws = l
    }

    private func accept(_ c: NWConnection) {
        let client = WSClient(conn: c)
        let id = ObjectIdentifier(c)
        clients[id] = client
        c.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.drop(id) }
            if case .cancelled = st { self?.drop(id) }
        }
        c.start(queue: queue)
        receive(client)
    }

    private func receive(_ client: WSClient) {
        client.conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.handle(data, client: client) }
            if error == nil { self.receive(client) } else { self.drop(ObjectIdentifier(client.conn)) }
        }
    }

    private func send(_ data: Data, to client: WSClient) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "bin", metadata: [meta])
        client.conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func handle(_ data: Data, client: WSClient) {
        guard let server, let (kind, body) = Wire.parse(data) else { return }
        switch kind {
        case .pairKnock:
            server.knock(String(decoding: body.dropFirst(16), as: UTF8.self))
        case .pairRequest:
            guard let req = Pairing.Request.parse(body) else { return }
            client.opener = nil
            send(server.pair(req), to: client)
        case .data:
            let b = Data(body)
            guard b.count >= 16, let sender = UUID(data: b.prefix(16)) else { return }
            if client.opener == nil || client.peerID != sender {
                guard let peer = server.store.peer(sender) else {
                    send(Wire.frame(.needPairing, LocalIdentity.id.data), to: client); return
                }
                client.peerID = sender
                client.opener = Opener(key: SymmetricKey(data: peer.receiveKey))
                client.sealer = Sealer(key: SymmetricKey(data: peer.sendKey))
            }
            do {
                let (_, plain) = try client.opener!.open(body)
                guard let msg = Msg.decode(plain) else { return }
                server.perform(msg, peerID: sender) { reply in
                    if let d = client.sealer?.seal(reply.encode(), senderID: LocalIdentity.id) { send(d, to: client) }
                }
            } catch Opener.Failure.replay {
                return
            } catch {
                client.opener = nil
                send(Wire.frame(.needPairing, LocalIdentity.id.data), to: client)
            }
        default: break
        }
    }

    private func drop(_ id: ObjectIdentifier) {
        if let c = clients.removeValue(forKey: id), let p = c.peerID { server?.dropExternal(p) }
    }
}
