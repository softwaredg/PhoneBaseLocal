import UIKit

final class RootViewController: UIViewController {
    private let runtime: BaseRuntime
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let ipLabel = UILabel()
    private let toggleButton = UIButton(type: .system)

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

        toggleButton.setTitle("停止服务", for: .normal)
        toggleButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        toggleButton.backgroundColor = UIColor(red: 0.18, green: 0.62, blue: 0.48, alpha: 1)
        toggleButton.setTitleColor(.white, for: .normal)
        toggleButton.layer.cornerRadius = 10
        toggleButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        toggleButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, ipLabel, toggleButton])
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
}
