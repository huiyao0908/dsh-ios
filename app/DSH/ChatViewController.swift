//  ChatViewController.swift - 「对话」Tab
//  职责：确保 DSH 引擎在跑，然后把 WKWebView 指向它。
import UIKit
import WebKit

final class ChatViewController: UIViewController, WKNavigationDelegate {
    private var web: WKWebView!
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "DeepSeek Harness"

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        web.isHidden = true
        view.addSubview(web)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        status.numberOfLines = 0
        status.textAlignment = .center
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabel
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 20),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self, action: #selector(reload))

        boot()
    }

    private func boot() {
        status.text = "正在启动引擎..."
        DSHServer.shared.start { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let url):
                    self.status.text = ""
                    self.spinner.stopAnimating()
                    self.web.isHidden = false
                    self.web.load(URLRequest(url: url))
                case .failure(let err):
                    self.spinner.stopAnimating()
                    self.status.text = "引擎启动失败\n\n\(err.localizedDescription)\n\n到「环境」页看 Node 体检与日志"
                    self.status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                }
            }
        }
    }

    @objc private func reload() { boot() }
}