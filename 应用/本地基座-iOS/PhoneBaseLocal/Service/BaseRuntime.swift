import Foundation
import UIKit

/// 非商业本地基座运行时：HTTP + /video + /control，licenseRequired=false
final class BaseRuntime {
    static let shared = BaseRuntime()

    let port: UInt16 = 11019
    private(set) var isRunning = false
    var onStatus: ((String) -> Void)?

    private let server: LocalHTTPServer
    private let publisher: FramePublisher
    private let controlHub: ControlHub
    private let sampler: ScreenSampler
    private let injector: TouchInjector
    private var geometryRevision = 1
    /// 缓存屏幕尺寸 / 名称，避免 HTTP 线程碰 UIKit
    private let screenWidth: Int
    private let screenHeight: Int
    private let cachedName: String
    private let cachedDeviceId: String
    private let hidReady: Bool

    private init() {
        let size = DeviceIdentity.screenSize()
        screenWidth = size.width
        screenHeight = size.height
        cachedName = DeviceIdentity.displayName
        cachedDeviceId = DeviceIdentity.deviceId
        let encodeW = min(max(size.width, 2), 720)
        let encodeH = min(max(size.height, 2), 1280)
        publisher = FramePublisher(width: encodeW, height: encodeH)
        let inj = TouchInjectors.best()
        injector = inj
        hidReady = (inj as? IOHIDTouchInjector)?.isAvailable == true
        controlHub = ControlHub(
            deviceId: cachedDeviceId,
            width: encodeW,
            height: encodeH,
            revision: geometryRevision,
            injector: inj,
            textAvailable: hidReady,
            keyboardAvailable: hidReady
        )
        sampler = ScreenSampler(width: encodeW, height: encodeH)
        server = LocalHTTPServer(port: port)
        server.bonjourName = cachedName
        server.bonjourTXT = [
            "protocol": "lan-phonebase",
            "version": "1.0",
            "deviceId": cachedDeviceId,
            "port": String(port),
        ]

        server.onInfo = { [weak self] in self?.infoJSON() ?? Data() }
        server.onHealth = { [weak self] in
            let n = self?.server.acceptCount ?? 0
            return Data("{\"ok\":true,\"protocol\":\"lan-phonebase\",\"version\":\"1.0\",\"accept\":\(n)}".utf8)
        }
        server.onAccepted = { [weak self] count, ip in
            self?.notify("有连接 #\(count) from \(ip)")
        }
        server.onVideoConnect = { [weak self] session in
            self?.publisher.attach(session)
        }
        server.onControlConnect = { [weak self] session in
            self?.controlHub.attach(session)
        }

        publisher.onTimestampUs = { [weak self] ts in
            self?.controlHub.latestFrameTimestampUs = ts
        }
        sampler.onPixelBuffer = { [weak self] buffer, pts in
            self?.publisher.encode(buffer: buffer, presentationTime: pts)
        }
        // geometry in /api/info stays full screen points*scale; stream is encodeW×encodeH
    }

    @discardableResult
    func start(notifyStatus: Bool = true) -> Bool {
        guard !isRunning else { return true }
        do {
            try server.start()
            sampler.start()
            isRunning = true
            if notifyStatus {
                let ips = LanAddress.ipv4List().joined(separator: ", ")
                notify("服务已启动 · \(ips.isEmpty ? "无IP" : ips):\(port)\nbuild=0.1.10-free-port\ndeviceId=\(cachedDeviceId)")
            }
            return true
        } catch {
            if notifyStatus {
                notify("启动失败: \(error)\n请点「释放端口占用」；若仍失败请卸载 Direct/旧基座后重开")
            }
            return false
        }
    }

    func stop() {
        guard isRunning else { return }
        sampler.stop()
        publisher.detachAll()
        controlHub.detachAll()
        server.stop()
        isRunning = false
        notify("服务已停止")
    }

    func setStreamingActive(_ active: Bool) {
        sampler.setActive(active)
        publisher.setPublisherOnline(active && isRunning)
    }

    private func notify(_ text: String) {
        onStatus?(text)
    }

    private func infoJSON() -> Data {
        let w = screenWidth
        let h = screenHeight
        let body: [String: Any] = [
            "protocol": "lan-phonebase",
            "version": "1.0",
            "deviceId": cachedDeviceId,
            "name": cachedName,
            "port": Int(port),
            "streaming": sampler.isActive,
            "width": w,
            "height": h,
            "controlAvailable": true,
            "homeAvailable": true,
            "textAvailable": hidReady,
            "keyboardAvailable": hidReady,
            "wallVideo": true,
            "licenseRequired": false,
            "release": [
                "product": "local",
                "version": "0.1.10",
                "buildId": "local-rebuild-0.1.10-free-port",
            ],
            "geometry": [
                "width": w,
                "height": h,
                "sourceWidth": w,
                "sourceHeight": h,
                "orientation": 1,
                "revision": geometryRevision,
                "changedAtUs": Int(Date().timeIntervalSince1970 * 1_000_000),
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
    }
}
