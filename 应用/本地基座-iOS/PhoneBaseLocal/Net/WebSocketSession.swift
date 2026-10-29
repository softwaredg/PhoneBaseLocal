import Foundation
import Darwin

final class WebSocketSession {
    private var fd: Int32
    private let queue: DispatchQueue
    private var buffer = Data()
    private var ownsFd = true
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private(set) var isOpen = true

    init(socketFd: Int32, queue: DispatchQueue) {
        self.fd = socketFd
        self.queue = queue
        var yes: Int32 = 1
        setsockopt(socketFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    }

    /// 标记 fd 已移交，调用方不要再 close
    @discardableResult
    func takeOwnership() -> Int32 {
        ownsFd = true
        return fd
    }

    func start() {
        queue.async { [weak self] in self?.receiveLoop() }
    }

    func sendText(_ text: String) {
        guard isOpen, let payload = text.data(using: .utf8) else { return }
        send(frame: encodeFrame(opcode: 0x1, payload: payload))
    }

    func sendBinary(_ data: Data) {
        guard isOpen else { return }
        send(frame: encodeFrame(opcode: 0x2, payload: data))
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        send(frame: encodeFrame(opcode: 0x8, payload: Data()))
        if ownsFd, fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        onClose?()
    }

    private func send(frame: Data) {
        guard fd >= 0 else { return }
        _ = frame.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.send(fd, base, frame.count, 0)
        }
    }

    private func receiveLoop() {
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        while isOpen, fd >= 0 {
            let n = Darwin.recv(fd, &tmp, tmp.count, 0)
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: tmp.prefix(n))
            consumeFrames()
            if !isOpen { return }
        }
        if isOpen {
            isOpen = false
            if ownsFd, fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
            onClose?()
        }
    }

    private func consumeFrames() {
        while true {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[0]
            let b1 = buffer[1]
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var offset = 2
            if len == 126 {
                guard buffer.count >= 4 else { return }
                len = Int(buffer[2]) << 8 | Int(buffer[3])
                offset = 4
            } else if len == 127 {
                guard buffer.count >= 10 else { return }
                len = 0
                for i in 0..<8 { len = (len << 8) | Int(buffer[2 + i]) }
                offset = 10
            }
            let maskLen = masked ? 4 : 0
            guard buffer.count >= offset + maskLen + len else { return }
            var payload = Data(buffer[(offset + maskLen)..<(offset + maskLen + len)])
            if masked {
                let mask = Array(buffer[offset..<(offset + 4)])
                for i in 0..<payload.count {
                    payload[i] ^= mask[i % 4]
                }
            }
            buffer.removeSubrange(0..<(offset + maskLen + len))

            switch opcode {
            case 0x1:
                if let text = String(data: payload, encoding: .utf8) { onText?(text) }
            case 0x2:
                onBinary?(payload)
            case 0x8:
                isOpen = false
                if ownsFd, fd >= 0 {
                    Darwin.close(fd)
                    fd = -1
                }
                onClose?()
                return
            case 0x9:
                send(frame: encodeFrame(opcode: 0xA, payload: payload))
            default:
                break
            }
        }
    }

    private func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode)
        let count = payload.count
        if count < 126 {
            frame.append(UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((count >> 8) & 0xFF))
            frame.append(UInt8(count & 0xFF))
        } else {
            frame.append(127)
            var n = UInt64(count).bigEndian
            withUnsafeBytes(of: &n) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }
}
