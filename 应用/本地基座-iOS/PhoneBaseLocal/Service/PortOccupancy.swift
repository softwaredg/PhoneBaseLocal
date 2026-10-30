import Foundation
import Darwin

/// 尝试清掉占用 11019 的其它基座进程（需 TrollStore + no-sandbox 才有机会生效）。
enum PortOccupancy {
    /// 常见冲突进程名（p_comm 最长 16 字节，匹配前缀即可）
    static let conflictNames: [String] = [
        "DirectPhoneBase",
        "DirectPhoneBas",
        "LanCaptureHelpe",
        "LanCaptureHelper",
        "PhoneBase",
        "phonebase",
        "PhoneBaseDirect",
        "PBHelper",
        "ScreenCaptureKi", // ScreenCaptureKit helper 偶发
    ]

    struct Result {
        var killed: [String] = []
        var notes: [String] = []
        var portFree: Bool = false
    }

    /// 杀掉冲突进程，并检测 11019 是否已可 bind。
    static func freePort(_ port: UInt16 = 11019) -> Result {
        var out = Result()
        let selfPid = getpid()

        // 1) 按进程名 SIGTERM → SIGKILL
        let procs = listProcesses()
        for p in procs {
            guard p.pid != selfPid, p.pid > 1 else { continue }
            let hit = conflictNames.contains { name in
                p.name.caseInsensitiveCompare(String(name.prefix(16))) == .orderedSame
                    || p.name.lowercased().hasPrefix("direct")
                    || p.name.lowercased().hasPrefix("lancapture")
                    || p.name.lowercased() == "phonebase"
            }
            // 避免误杀自己：本进程可执行文件名是 PhoneBaseLocal
            if p.name.hasPrefix("PhoneBaseLocal") { continue }
            if hit {
                var ok = Darwin.kill(p.pid, SIGTERM) == 0
                usleep(80_000)
                if Darwin.kill(p.pid, 0) == 0 {
                    ok = Darwin.kill(p.pid, SIGKILL) == 0 || ok
                }
                if ok {
                    out.killed.append("\(p.name)(\(p.pid))")
                } else {
                    out.notes.append("kill \(p.name)(\(p.pid)) errno=\(errno)")
                }
            }
        }

        // 2) killall 兜底（巨魔环境有时可用）
        for name in ["DirectPhoneBase", "LanCaptureHelper", "PhoneBase"] {
            let r = runKillall(name)
            if !r.isEmpty { out.notes.append(r) }
        }

        usleep(200_000)

        // 3) 探测端口是否空闲（能 bind 即空闲）
        out.portFree = canBind(port: port)
        if out.portFree {
            out.notes.append("端口 \(port) 已可绑定")
        } else {
            out.notes.append("端口 \(port) 仍被占用（errno=\(errno)）")
        }
        return out
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
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/usr/bin/killall"),
            strdup("-9"),
            strdup(name),
            nil,
        ]
        defer {
            argv.forEach { if let p = $0 { free(p) } }
        }
        let rc = argv.withUnsafeMutableBufferPointer { ptr -> Int32 in
            posix_spawn(&pid, "/usr/bin/killall", nil, nil, ptr.baseAddress, nil)
        }
        if rc != 0 {
            // 部分设备无 killall，静默即可
            return ""
        }
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
