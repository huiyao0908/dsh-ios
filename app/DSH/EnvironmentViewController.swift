//  EnvironmentViewController.swift - 「环境」Tab
//  显示：Node 体检结果 / 引擎状态 / 路径 / 一键安装 / 日志
//
//  关于「一键安装」真的在做什么：
//    iOS 内核 + amfi + W^X 禁止运行时下载并执行新二进制，
//    所以依赖全部打包在 IPA 里，点击只是：
//      1) 把 profile 从 bundle 复制到 Documents
//      2) 建数据目录树
//      3) 校验 node 二进制可执行且已签名
//      4) 写 .credentials.yaml
//      5) 试启动引擎
//    这与 iSH / a-Shell / Pyto 同一套做法。
import UIKit

final class EnvironmentViewController: UIViewController {

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let logView = UITextView()
    private let probeView = UITextView()
    private let installButton = UIButton(type: .system)
    private var dynamicRows: [UIView] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "环境"
        view.backgroundColor = .systemBackground

        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])

        var cfg = UIButton.Configuration.filled()
        cfg.title = "一键安装环境"
        installButton.configuration = cfg
        installButton.addTarget(self, action: #selector(installTapped), for: .touchUpInside)

        let mono = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        for tv in [probeView, logView] {
            tv.font = mono; tv.isEditable = false
            tv.backgroundColor = .secondarySystemBackground
            tv.layer.cornerRadius = 8
            tv.translatesAutoresizingMaskIntoConstraints = false
        }
        probeView.heightAnchor.constraint(equalToConstant: 190).isActive = true
        logView.heightAnchor.constraint(equalToConstant: 240).isActive = true

        stack.addArrangedSubview(header("诊断"))
        stack.addArrangedSubview(installButton)
        let btns = UIStackView(arrangedSubviews: [
            button("重新检查", #selector(refreshTapped)),
            button("重启引擎", #selector(restartEngine)),
            button("清空数据", #selector(wipeTapped)),
        ])
        btns.distribution = .fillEqually; btns.spacing = 8
        stack.addArrangedSubview(btns)
        stack.addArrangedSubview(header("Node 体检"))
        stack.addArrangedSubview(probeView)
        stack.addArrangedSubview(header("引擎日志"))
        stack.addArrangedSubview(logView)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    private func header(_ t: String) -> UILabel {
        let l = UILabel(); l.text = t; l.font = .boldSystemFont(ofSize: 15); return l
    }
    private func button(_ t: String, _ sel: Selector) -> UIButton {
        let b = UIButton(type: .system); b.setTitle(t, for: .normal)
        b.addTarget(self, action: sel, for: .touchUpInside); return b
    }

    @objc private func refresh() {
        for v in dynamicRows { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        dynamicRows = []

        let fm = FileManager.default
        let probed = DSHPaths.nodeCandidates.map { c -> (String, Bool) in
            (c.path, fm.isExecutableFile(atPath: c.path))
        }
        let rows: [(String, Bool, String)] = [
            ("引擎文件",     fm.fileExists(atPath: DSHPaths.dshCli.path), ""),
            ("Profile",      fm.fileExists(atPath: DSHPaths.profiles.path), ""),
            ("工作目录",     fm.fileExists(atPath: DSHPaths.workspace.path), ""),
            ("API Key",      !(Settings.shared.apiKey ?? "").isEmpty, ""),
            ("引擎运行中",   DSHServer.shared.currentURL() != nil, ""),
        ]
        for (name, ok, extra) in rows {
            addRow(name: name, ok: ok, detail: extra)
        }
        addSubheader("Node 候选（按优先级）")
        for (path, exists) in probed {
            addRow(name: (path as NSString).lastPathComponent, ok: exists, detail: path)
        }

        // 体检日志
        let pl = (try? String(contentsOf: DSHPaths.probeLog, encoding: .utf8)) ?? "（尚未体检。点「重启引擎」执行。）"
        probeView.text = pl

        // 引擎日志
        let t = (try? String(contentsOf: DSHServer.shared.logURL, encoding: .utf8)) ?? "（无日志）"
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
        logView.text = lines.suffix(160).joined(separator: "\n")
    }

    private func addSubheader(_ t: String) {
        let l = UILabel(); l.text = t; l.font = .systemFont(ofSize: 13); l.textColor = .secondaryLabel
        if let i = stack.arrangedSubviews.firstIndex(of: installButton) {
            stack.insertArrangedSubview(l, at: i)
        } else { stack.addArrangedSubview(l) }
        dynamicRows.append(l)
    }

    private func addRow(name: String, ok: Bool, detail: String) {
        let row = UIStackView(); row.axis = .vertical; row.spacing = 1
        let top = UIStackView(); top.axis = .horizontal
        let n = UILabel(); n.text = name; n.font = .systemFont(ofSize: 14)
        let s = UILabel()
        s.text = ok ? "✓" : "✗"
        s.textColor = ok ? .systemGreen : .systemRed
        s.font = .boldSystemFont(ofSize: 16)
        top.addArrangedSubview(n); top.addArrangedSubview(UIView()); top.addArrangedSubview(s)
        row.addArrangedSubview(top)
        if !detail.isEmpty {
            let d = UILabel(); d.text = detail
            d.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
            d.textColor = .tertiaryLabel
            d.numberOfLines = 2
            d.lineBreakMode = .byTruncatingMiddle
            row.addArrangedSubview(d)
        }
        if let i = stack.arrangedSubviews.firstIndex(of: installButton) {
            stack.insertArrangedSubview(row, at: i)
        } else { stack.addArrangedSubview(row) }
        dynamicRows.append(row)
    }

    @objc private func refreshTapped() { refresh() }

    @objc private func installTapped() {
        do {
            try DSHPaths.seedIfNeeded()
            try Settings.shared.writeCredentials()
            guard let (node, ver) = DSHPaths.resolveNode() else {
                alert("安装失败", "没找到可用的 Node 运行时。请看下方 Node 候选列表。")
                refresh(); return
            }
            alert("安装完成", "Profile 已就位，数据目录已创建。\n\nNode: \(node.path)\n版本: \(ver)")
        } catch {
            alert("安装失败", error.localizedDescription)
        }
        refresh()
    }

    @objc private func restartEngine() {
        DSHServer.shared.stop()
        DSHServer.shared.start(force: true) { r in
            DispatchQueue.main.async {
                switch r {
                case .success(let u):
                    self.alert("引擎已启动", u.absoluteString)
                case .failure(let e):
                    self.alert("启动失败", e.localizedDescription)
                }
                self.refresh()
            }
        }
    }

    @objc private func wipeTapped() {
        let a = UIAlertController(title: "清空数据",
            message: "将删除 dsh-home 下的会话与配置，不可恢复。",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in
            try? FileManager.default.removeItem(at: DSHPaths.home)
            try? DSHPaths.seedIfNeeded()
            self.refresh()
        })
        present(a, animated: true)
    }

    private func alert(_ t: String, _ m: String) {
        let a = UIAlertController(title: t, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}