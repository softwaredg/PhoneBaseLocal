import UIKit

final class RootViewController: UIViewController {
    private let runtime: BaseRuntime
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let ipLabel = UILabel()
    private let selfTestLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private let selfTestButton = UIButton(type: .system)

    init(runtime: BaseRuntime) {
        self.runtime = runtime
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.11, alpha: 1)

        titleLabel.text = "本地基座"
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white

        statusLabel.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        statusLabel.textColor = UIColor(white: 0.75, alpha: 1)
        statusLabel.numberOfLines = 0

        ipLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        ipLabel.textColor = UIColor(white: 0.55, alpha: 1)
        ipLabel.numberOfLines = 0

        selfTestLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        selfTestLabel.textColor = UIColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 1)
        selfTestLabel.numberOfLines = 0
        selfTestLabel.text = "点「本机自检」验证 /api/health 是否本进程在响应"

        toggleButton.setTitle("停止服务", for: .normal)
        stylePrimary(toggleButton, color: UIColor(red: 0.18, green: 0.62, blue: 0.48, alpha: 1))
        toggleButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        selfTestButton.setTitle("本机自检", for: .normal)
        stylePrimary(selfTestButton, color: UIColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 1))
        selfTestButton.addTarget(self, action: #selector(runSelfTest), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, statusLabel, ipLabel, selfTestLabel, toggleButton, selfTestButton,
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 36),
        ])

        runtime.onStatus = { [weak self] text in
            DispatchQueue.main.async { self?.statusLabel.text = text }
        }
        refreshIP()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshIP()
        }

        // 启动后自动自检一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runSelfTest()
        }
    }

    private func stylePrimary(_ button: UIButton, color: UIColor) {
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
    }

    private func refreshIP() {
        let ips = LanAddress.ipv4List().joined(separator: "\n")
        let tip = ips.isEmpty
            ? "等待局域网地址…\n请确认手机已连 Wi‑Fi（勿用访客网络）"
            : "电脑端「手动添加」填：\n\(ips.split(separator: "\n").first ?? "")\n端口 \(runtime.port)"
        ipLabel.text = "端口 \(runtime.port)\n\(ips.isEmpty ? "无局域网 IP" : ips)\n\n\(tip)"
    }

    @objc private func toggle() {
        if runtime.isRunning {
            runtime.stop()
            toggleButton.setTitle("启动服务", for: .normal)
        } else {
            runtime.start()
            toggleButton.setTitle("停止服务", for: .normal)
        }
        refreshIP()
    }

    @objc private func runSelfTest() {
        selfTestLabel.text = "自检中…"
        let port = runtime.port
        let lan = LanAddress.ipv4List().first
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let local = Self.fetch("http://127.0.0.1:\(port)/api/health")
            let lanResult: String
            if let lan {
                lanResult = Self.fetch("http://\(lan):\(port)/api/health")
            } else {
                lanResult = "无局域网 IP"
            }
            DispatchQueue.main.async {
                self?.selfTestLabel.text = "本机自检\n127.0.0.1 → \(local)\nLAN → \(lanResult)\n\n电脑连入时上方应出现「有连接 #N」"
            }
        }
    }

    private static func fetch(_ url: String) -> String {
        guard let u = URL(string: url) else { return "bad-url" }
        var req = URLRequest(url: u, timeoutInterval: 2.5)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var out = "timeout"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err {
                out = "err:\(err.localizedDescription)"
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            out = "HTTP \(code) \(body)"
        }.resume()
        _ = sem.wait(timeout: .now() + 3)
        return out
    }
}
