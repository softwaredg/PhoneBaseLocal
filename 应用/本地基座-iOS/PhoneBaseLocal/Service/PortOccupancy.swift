import Foundation
import Darwin

/// 清掉占用 11019 的其它基座进程（需 TrollStore + 无沙盒）。
/// 注意：绝不能 `killall PhoneBaseLocal`，会把自己杀掉。
enum PortOccupancy {
    struct Result {
        var killed: [String] = []
        var notes: [String] = []
        var seen: [String] = []
        var occupantHint: String = ""
        var portFree: Bool = false
    }

    static func freePort(_ port: UInt16 = 11019) -> Result {
        var out = Result()
        let selfPid = getpid()
        out.notes.append("selfPid=\(selfPid)")
        out.occupantHint = probeOccupant(port: port)

        let procs = listProcesses()
        for p in procs where isConflict(p.name) {
            out.seen.append("\(p.name)(\(p.pid))")
        }

        // 只按 PID 杀「别人」，永不 killall 自己的可执行名
        for p in procs {
            guard p.pid != selfPid, p.pid > 1 else { continue }
            guard isConflict(p.name) else { continue }
            killPid(p.pid, name: p.name, into: &out)
        }

        for name in ["PhoneBaseDirect", "LanCaptureHelper", "DirectPhoneBase", "PhoneBase"] {
            let r = runKillall(name)
            if !r.isEmpty { out.notes.append(r) }
        }

        usleep(300_000)

        if !canBind(port: port) {
            let again = listProcesses()
            for p in again {
                guard p.pid != selfPid, p.pid > 1, isConflict(p.name) else { continue }
                _ = Darwin.kill(p.pid, SIGKILL)
                out.notes.append("retry SIGKILL \(p.name)(\(p.pid))")
            }
            usleep(250_000)
        }

        out.portFree = canBind(port: port)
        if out.seen.isEmpty {
            out.notes.append("未枚举到冲突进程（无 list 权限或占用者名不同）")
        } else {
            out.notes.append("见过：\(out.seen.joined(separator: ", "))")
        }
        if out.portFree {
            out.notes.append("端口 \(port) 已可绑定")
        } else {
            out.notes.append("端口 \(port) 仍被占用")
        }
        return out
    }

    /// 读占用方 /api/info，便于区分旧本地基座 vs Direct
    private static func probeOccupant(port: UInt16) -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/info") else { return "" }
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var text = ""
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            if let d = data,
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                let proto = obj["protocol"] ?? ""
                let ver = obj["version"] ?? obj["buildId"] ?? ""
                let pub = obj["publisherType"] ?? ""
                let name = obj["name"] ?? ""
                let bid = obj["buildId"] ?? ""
                text = "占用方 HTTP \(code) protocol=\(proto) build=\(bid) ver=\(ver) publisher=\(pub) name=\(name)"
            } else {
                let short = body.count > 80 ? String(body.prefix(80)) + "…" : body
                text = "占用方 HTTP \(code) \(short)"
            }
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return text
    }

    private static func isConflict(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("phonebaselocal") { return true }
        if lower.hasPrefix("phonebasedirect") { return true }
        if lower.hasPrefix("direct") { return true }
        if lower.hasPrefix("lancapture") { return true }
        if lower == "phonebase" { return true }
        return false
    }

    private static func killPid(_ pid: pid_t, name: String, into out: inout Result) {
        var ok = Darwin.kill(pid, SIGTERM) == 0
        usleep(120_000)
        if Darwin.kill(pid, 0) == 0 {
            ok = Darwin.kill(pid, SIGKILL) == 0 || ok
            usleep(80_000)
        }
        if Darwin.kill(pid, 0) != 0 {
            out.killed.append("\(name)(\(pid))")
        } else if ok {
            out.killed.append("\(name)(\(pid))?")
            out.notes.append("kill \(name)(\(pid)) 已发信号但仍存活 errno=\(errno)")
        } else {
            out.notes.append("kill \(name)(\(pid)) 失败 errno=\(errno)")
        }
    }

    private struct Proc {
        var pid: pid_t
        var name: String
    }

    private static func listProcesses() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        if sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) != 0 || size == 0 {
            return []
        }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
        if sysctl(&mib, u_int(mib.count), &buf, &size, nil, 0) != 0 {
            return []
        }
        let n = size / MemoryLayout<kinfo_proc>.stride
        var list: [Proc] = []
        list.reserveCapacity(n)
        for i in 0..<n {
            let kp = buf[i]
            let pid = kp.kp_proc.p_pid
            var comm = kp.kp_proc.p_comm
            let name = withUnsafePointer(to: &comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }
            if !name.isEmpty {
                list.append(Proc(pid: pid, name: name))
            }
        }
        return list
    }

    private static func runKillall(_ name: String) -> String {
        // 禁止对本包名 killall
        if name.lowercased().hasPrefix("phonebaselocal") { return "" }
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/usr/bin/killall"),
            strdup("-9"),
            strdup(name),
            nil,
        ]
        defer { argv.forEach { if let p = $0 { free(p) } } }
        let rc = argv.withUnsafeMutableBufferPointer { ptr -> Int32 in
            posix_spawn(&pid, "/usr/bin/killall", nil, nil, ptr.baseAddress, nil)
        }
        if rc != 0 { return "" }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return "killall -9 \(name) status=\(status)"
    }

    private static func canBind(port: UInt16) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        memset(&addr, 0, MemoryLayout<sockaddr_in>.size)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ok == 0
    }
}
