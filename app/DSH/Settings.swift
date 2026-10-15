//  Settings.swift - 设置页的数据源，UserDefaults 持久化。
import Foundation

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum K {
        static let apiKey = "dsh.apiKey"
        static let provider = "dsh.provider"
        static let model = "dsh.model"
        static let reasoning = "dsh.reasoning"
        static let permission = "dsh.permissionMode"
        static let autoStart = "dsh.autoStart"
        static let baseURL = "dsh.baseURL"
    }

    var apiKey: String? {
        get { d.string(forKey: K.apiKey) }
        set { d.set(newValue, forKey: K.apiKey) }
    }
    /// 服务商：deepseek-official / volcengine / aliyun / custom
    var provider: String {
        get { d.string(forKey: K.provider) ?? "deepseek-official" }
        set { d.set(newValue, forKey: K.provider) }
    }
    var model: String {
        get { d.string(forKey: K.model) ?? "deepseek-flash" }
        set { d.set(newValue, forKey: K.model) }
    }
    var reasoningEffort: String {
        get { d.string(forKey: K.reasoning) ?? "high" }
        set { d.set(newValue, forKey: K.reasoning) }
    }
    var permissionMode: String {
        get { d.string(forKey: K.permission) ?? "danger-full-access" }
        set { d.set(newValue, forKey: K.permission) }
    }
    var autoStartEngine: Bool {
        get { d.object(forKey: K.autoStart) as? Bool ?? true }
        set { d.set(newValue, forKey: K.autoStart) }
    }
    var customBaseURL: String? {
        get { d.string(forKey: K.baseURL) }
        set { d.set(newValue, forKey: K.baseURL) }
    }

    /// 写出 .credentials.yaml，格式与桌面版一致（refs 段）。
    func writeCredentials() throws {
        guard let key = apiKey, !key.isEmpty else { return }
        let yaml = "refs:\n  DEEPSEEK_API_KEY: \(key)\n"
        try yaml.write(to: DSHPaths.credentials, atomically: true, encoding: .utf8)
    }
}