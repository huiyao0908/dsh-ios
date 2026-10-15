//  SettingsViewController.swift - 「设置」 Tab
//  API Key / 服务商 / 模型 / 推理等级 / 权限模式 / 工作目录。
import UIKit

final class SettingsViewController: UITableViewController {

    private let providers = ["deepseek-official", "volcengine", "aliyun", "custom"]
    private let models = ["deepseek-flash", "deepseek-v4-pro"]
    private let efforts = ["off", "low", "high", "max"]
    private let perms = ["read-only", "workspace-write", "danger-full-access"]

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
    }

    private enum Row: Int, CaseIterable {
        case apiKey, provider, model, effort, perm, autoStart, workspace, about
        var title: String {
            switch self {
            case .apiKey:    return "API Key"
            case .provider:  return "服务商"
            case .model:     return "模型"
            case .effort:    return "推理等级"
            case .perm:      return "权限模式"
            case .autoStart: return "启动时自动开引擎"
            case .workspace: return "工作目录"
            case .about:     return "关于"
            }
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { Row.allCases.count }

    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "c", for: ip)
        var cfg = c.defaultContentConfiguration()
        let row = Row(rawValue: ip.row)!
        cfg.text = row.title
        cfg.secondaryText = value(for: row)
        c.contentConfiguration = cfg
        c.accessoryType = (row == .autoStart) ? .none : .disclosureIndicator
        if row == .autoStart {
            let sw = UISwitch()
            sw.isOn = Settings.shared.autoStartEngine
            sw.addTarget(self, action: #selector(autoStartChanged(_:)), for: .valueChanged)
            c.accessoryView = sw
        }
        return c
    }

    private func value(for row: Row) -> String {
        switch row {
        case .apiKey:
            let k = Settings.shared.apiKey ?? ""
            return k.isEmpty ? "未设置" : String(k.prefix(6)) + "…" + String(k.suffix(4))
        case .provider:  return Settings.shared.provider
        case .model:     return Settings.shared.model
        case .effort:    return Settings.shared.reasoningEffort
        case .perm:      return Settings.shared.permissionMode
        case .autoStart: return ""
        case .workspace: return DSHPaths.workspace.path
        case .about:     return "dsh 0.2.0-rc.2"
        }
    }

    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        let row = Row(rawValue: ip.row)!
        switch row {
        case .apiKey:    promptApiKey()
        case .provider:  pick("服务商", providers, Settings.shared.provider) { Settings.shared.provider = $0 }
        case .model:     pick("模型", models, Settings.shared.model) { Settings.shared.model = $0 }
        case .effort:    pick("推理等级", efforts, Settings.shared.reasoningEffort) { Settings.shared.reasoningEffort = $0 }
        case .perm:      pick("权限模式", perms, Settings.shared.permissionMode) { Settings.shared.permissionMode = $0; DSHServer.shared.stop() }
        case .autoStart: break
        case .workspace:
            let a = UIAlertController(title: "工作目录", message: DSHPaths.workspace.path, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "打开\u{Files}", style: .default) { _ in
                let u = DSHPaths.workspace
                let av = UIActivityViewController(activityItems: [u], applicationActivities: nil)
                self.present(av, animated: true)
            })
            a.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(a, animated: true)
        case .about:
            let a = UIAlertController(title: "DeepSeek Harness iOS",
                message: "dsh 0.2.0-rc.2\nNode 运行时：自编（arm64-apple-ios）\nUI：dsh 原版 Web 前端",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
        }
        tableView.reloadData()
    }

    private func promptApiKey() {
        let a = UIAlertController(title: "API Key", message: "填写 DeepSeek 平台的 API Key，仅存本机", preferredStyle: .alert)
        a.addTextField { $0.placeholder = "sk-..."; $0.text = Settings.shared.apiKey; $0.autocapitalizationType = .none }
        a.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            Settings.shared.apiKey = a.textFields?.first?.text
            try? Settings.shared.writeCredentials()
            self.tableView.reloadData()
        })
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(a, animated: true)
    }

    private func pick(_ title: String, _ opts: [String], _ cur: String, _ apply: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for o in opts {
            a.addAction(UIAlertAction(title: (o == cur ? "✓ " : "") + o, style: .default) { _ in
                apply(o); self.tableView.reloadData()
            })
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pc = a.popoverPresentationController { pc.sourceView = view; pc.sourceRect = view.bounds }
        present(a, animated: true)
    }

    @objc private func autoStartChanged(_ sw: UISwitch) { Settings.shared.autoStartEngine = sw.isOn }
}