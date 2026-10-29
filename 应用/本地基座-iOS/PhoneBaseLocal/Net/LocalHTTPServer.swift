import Foundation
import Network
import CommonCrypto

final class LocalHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private var bonjour: NetService?
    private let queue = DispatchQueue(label: "cn.local.phonebase.local.http")

    var onInfo: (() -> Data)?
    var onHealth: (() -> Data)?
    var onVideoConnect: ((WebSocketSession) -> Void)?
    var onControlConnect: ((WebSocketSession) -> Void)?

    /// Bonjour 展示名 / TXT（与 TCP 监听解耦，避免 mDNS 失败拖垮 HTTP）
    var bonjourName: String = "PhoneBaseLocal"
    var bonjourTXT: [String: String] = [:]

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // 不在这里挂 listener.service：部分机型上 Bonjour 注册异常会导致连接无响应
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                NSLog("[HTTP] listener ready on %u", self?.port ?? 0)
                self?.publishBonjour()
            case .failed(let error):
                NSLog("[HTTP] listener failed: %@", "\(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        bonjour?.stop()
        bonjour = nil
        listener?.cancel()
        listener = nil
    }

    private func publishBonjour() {
        queue.async { [weak self] in
            guard let self else { return }
            self.bonjour?.stop()
            let name = String(self.bonjourName.prefix(48))
            let svc = NetService(domain: "local.", type: "_phonebase._tcp.", name: name, port: Int32(self.port))
            var dict: [String: Data] = [:]
            for (k, v) in self.bonjourTXT {
                dict[k] = Data(v.utf8)
            }
            svc.setTXTRecord(NetService.data(fromTXTRecord: dict))
            svc.publish()
            self.bonjour = svc
            NSLog("[HTTP] bonjour published name=%@", name)
        }
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveHeader(connection: connection, accumulated: Data())
            case .failed(let error):
                NSLog("[HTTP] conn failed: %@", "\(error)")
                connection.cancel()
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveHeader(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = accumulated
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
                let rest = buf.subdata(in: range.upperBound..<buf.endIndex)
                self.route(connection: connection, headerData: headerData, leftover: rest)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            if buf.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.receiveHeader(connection: connection, accumulated: buf)
        }
    }

    private func route(connection: NWConnection, headerData: Data, leftover: Data) {
        guard let header = String(data: headerData, encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else {
            connection.cancel()
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }
        let method = String(parts[0])
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let idx = line.firstIndex(of: ":") {
                let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let upgrade = headers["upgrade"]?.lowercased() == "websocket"
        if upgrade && (path == "/video" || path == "/control") {
            acceptWebSocket(connection: connection, path: path, headers: headers, leftover: leftover)
            return
        }

        if method == "GET" && path == "/api/info" {
            // UIKit 相关字段已在 BaseRuntime 侧缓存；这里只取 JSON
            respond(connection: connection, status: 200, contentType: "application/json", body: onInfo?() ?? Data("{}".utf8))
        } else if method == "GET" && path == "/api/health" {
            respond(connection: connection, status: 200, contentType: "application/json", body: onHealth?() ?? Data("{}".utf8))
        } else if method == "OPTIONS" {
            respond(connection: connection, status: 204, contentType: "text/plain", body: Data())
        } else {
            respond(connection: connection, status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }
    }

    private func acceptWebSocket(connection: NWConnection, path: String, headers: [String: String], leftover: Data) {
        guard let key = headers["sec-websocket-key"] else {
            connection.cancel()
            return
        }
        let accept = WebSocketHandshake.acceptKey(clientKey: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }
            let session = WebSocketSession(connection: connection, queue: self?.queue ?? .main)
            _ = leftover
            session.start()
            if path == "/video" {
                self?.onVideoConnect?(session)
            } else {
                self?.onControlConnect?(session)
            }
        })
    }

    private func respond(connection: NWConnection, status: Int, contentType: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        default: reason = "ERR"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "\r\n"
        var packet = Data(header.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum WebSocketHandshake {
    static func acceptKey(clientKey: String) -> String {
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let data = Data(magic.utf8)
        data.withUnsafeBytes { buf in
            _ = CC_SHA1(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
    }
}
