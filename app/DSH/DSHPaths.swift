//  DSHPaths.swift - App 内所有固定路径。
//  iOS 沙箱：Bundle 只读，Documents 可写。引擎必须全部写在 Documents 下。
import Foundation

enum DSHPaths {
    static var bundle: URL { Bundle.main.bundleURL }
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // ---- 引擎（只读，来自 IPA）
    static var engineRoot: URL { bundle.appendingPathComponent("Resources/engine") }
    static var dshCli: URL {
        engineRoot.appendingPathComponent("dsh/node_modules/@deepseek-ai/dsh/lib/bin.js")
    }

    // ---- Node 运行时：三候选，按优先级探测
    //  ① 打包进 IPA 的（我们自己编的 Node 24 + 全 JIT）
    //  ② 用户手机上已装的（imcynic / j0shua 的 deb，装在 /var/jb/usr/local/lib/nodejs/node）
    //  ③ 备选路径
    //
    //  为什么用绝对路径而不是 PATH 里的 `node`：
    //   Sileo 装的 node 会在 /var/jb/usr/bin 或 ~/.zshrc 里放一个 wrapper，
    //   那 wrapper 会追加一串 V8 不认的参数（实测报错：
    //     /var/jb/usr/local/lib/nodejs/node: bad option:
    //     --no-wasm-code-gc --no-opt --no-sparkplug --single-threaded --liftoff --no-wasm-tier-up）
    //   直接调绝对路径就绕开 wrapper。
    static var nodeCandidates: [URL] {
        [
            bundle.appendingPathComponent("Frameworks/node"),
            URL(fileURLWithPath: "/var/jb/usr/local/lib/nodejs/node"),
            URL(fileURLWithPath: "/var/jb/usr/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node"),
        ]
    }

    /// 返回第一个存在且可执行、且能跑 `--version` 的 Node。
    /// 探测会真的启动进程，所以有副作用（约 200ms）——只在启动时做一次。
    static func resolveNode() -> (url: URL, version: String)? {
        for u in nodeCandidates where FileManager.default.isExecutableFile(atPath: u.path) {
            if let v = NodeProbe.runVersion(u) { return (u, v) }
        }
        return nil
    }

    // ---- 数据（可写）
    static var home: URL { documents.appendingPathComponent("dsh-home") }
    static var sessions: URL { home.appendingPathComponent("sessions") }
    static var storages: URL { home.appendingPathComponent("storages") }
    static var profiles: URL { home.appendingPathComponent("profiles") }
    static var credentials: URL { home.appendingPathComponent(".credentials.yaml") }
    static var logs: URL { documents.appendingPathComponent("logs") }
    static var workspace: URL { documents.appendingPathComponent("workspace") }
    static var probeLog: URL { logs.appendingPathComponent("node-probe.log") }

    /// 首次启动播种：建目录树 + 把 bundle 里的 profile 复制到 Documents。
    /// 引擎读 bundle 里的 node_modules 是只读的没问题，但 profile 目录必须可写，
    /// 因为 dsh plugin 会往 profiles/<name>/ 里写 pnpm 元数据。
    static func seedIfNeeded() throws {
        let fm = FileManager.default
        for d in [home, sessions, storages, profiles, logs, workspace] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let src = engineRoot.appendingPathComponent("profiles")
        if fm.fileExists(atPath: src.path) {
            let entries = (try? fm.contentsOfDirectory(atPath: src.path)) ?? []
            for e in entries {
                let dst = profiles.appendingPathComponent(e)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src.appendingPathComponent(e), to: dst)
                }
            }
        }
    }
}