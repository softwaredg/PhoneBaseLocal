import Foundation
import Network
import CommonCrypto

final class LocalHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cn.local.phonebase.local.http")

    var onInfo: (() -> Data)?
    var onHealth: (() -> Data)?
    var onVideoConnect: ((WebSocketSession) -> Void)?
    var onControlConnect: ((WebSocketSession) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    /// 可选 Bonjour 名称 / TXT（桌面扫描走 HTTP，官方客户端可走 mDNS）
    var bonjourName: String = "PhoneBaseLocal"
    var bonjourTXT: [String: String] = [:]

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        var txt = NWTXTRecord()
        for (k, v) in bonjourTXT {
            txt[k] = v
        }
        // 名字过长会导致 publish 失败；截断到安全长度
        let safeName = String(bonjourName.prefix(48))
        listener.service = NWListener.Service(name: safeName, type: "_phonebase._tcp", txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                NSLog("[HTTP] listener failed: %@", "\(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection: connection, accumulated: Data())
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
            respond(connection: connection, status: 200, contentType: "application/json", body: onInfo?() ?? Data("{}".utf8))
        } else if method == "GET" && path == "/api/health" {
            respond(connection: connection, status: 200, contentType: "application/json", body: onHealth?() ?? Data("{}".utf8))
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
            if !leftover.isEmpty {
                // leftover after header rarely contains WS frames; ignore for simplicity
            }
            session.start()
            if path == "/video" {
                self?.onVideoConnect?(session)
            } else {
                self?.onControlConnect?(session)
            }
        })
    }

    private func respond(connection: NWConnection, status: Int, contentType: String, body: Data) {
        let reason = status == 200 ? "OK" : "ERR"
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
