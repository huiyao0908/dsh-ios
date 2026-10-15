//  DSHServer.swift - 启动 / 守护 dsh 引擎进程
//  ---------------------------------------------------------------------------
//  引擎启动方式（桌面已验证的等价形态）：
//    <node> --expose-internals <cli.js> web --no-open --port 43129
//
//  iOS 上额外加的两个参数：
//    --predictable        让 V8 走确定性调度，W^X 权限翻转不会和后台编译线程抢
//    --single-threaded    强制单线程。j0shua-SYSON 在 A9 上验证过：mprotect 的
//                         W^X flip 是进程级全局的，多线程下会和 concurrent
//                         compiler 抢权限位，导致 SIGBUS。单线程是正确做法。
//
//  Node 来源：DSHPaths.nodeCandidates 三候选，逐个探测 `--version`，第一个能跑的赢。
//  探测用绝对路径，绕开 Sileo 往 PATH 里放的 wrapper（那 wrapper 会追加
//  --no-wasm-code-gc --no-opt --no-sparkplug 等一串 V8 不认的参数）。
import Foundation

enum DSHServerError: LocalizedError {
    case engineMissing
    case nodeMissing(probed: [String])
    case probeFailed(NodeProbe.Result)
    case spawnFailed(String)
    case exited(code: Int32)
    case timeout

    var errorDescription: String? {
        switch self {
        case .engineMissing:
            return "未找到引擎文件。请到「环境」页执行一键安装。"
        case .nodeMissing(let probed):
            return "没找到可用的 Node 运行时。已尝试：\n" + probed.joined(separator: "\n")
        case .probeFailed(let r):
            return "Node 体检未通过：\n" + r.failures.joined(separator: "\n")
        case .spawnFailed(let m):
            return "进程启动失败：\(m)"
        case .exited(let c):
            return "引擎进程已退出，代码 \(c)。详情见日志。"
        case .timeout:
            return "引擎启动超时（90s）。详情见日志。"
        }
    }
}

final class DSHServer {
    static let shared = DSHServer()

    private(set) var port: Int = 43129
    private(set) var token: String = ""
    private(set) var resolvedNode: URL?
    private(set) var probe: NodeProbe.Result?
    private(set) var lastError: DSHServerError?

    private var proc: Process?
    private var ready = false
    private var starting = false
    private var waiters: [(Result<URL, Error>) -> Void] = []

    var logURL: URL { DSHPaths.logs.appendingPathComponent("engine.log") }

    // ---------------------------------------------------------------- start
    func start(force: Bool = false, _ cb: @escaping (Result<URL, Error>) -> Void) {
        if ready, !force, let u = currentURL() { cb(.success(u)); return }
        waiters.append(cb)
        if starting { return }
        starting = true
        DispatchQueue.global(qos: .userInitiated).async { self.bootSequence() }
    }

    func currentURL() -> URL? {
        guard ready, !token.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = "http"; c.host = "127.0.0.1"; c.port = port; c.path = "/"
        c.queryItems = [URLQueryItem(name: "token", value: token)]
        return c.url
    }

    private func finish(_ r: Result<URL, Error>) {
        DispatchQueue.main.async {
            let ws = self.waiters; self.waiters = []
            for w in ws { w(r) }
            self.starting = false
        }
    }

    // ------------------------------------------------------- boot sequence
    private func bootSequence() {
        let fm = FileManager.default
        for d in [DSHPaths.home, DSHPaths.sessions, DSHPaths.storages, DSHPaths.profiles, DSHPaths.logs, DSHPaths.workspace] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        // ---- 1. 找 Node（绝对路径，绕开 wrapper）
        let probed = DSHPaths.nodeCandidates.map { $0.path + (fm.isExecutableFile(atPath: $0.path) ? " [存在]" : " [缺失]") }
        guard let (node, _) = DSHPaths.resolveNode() else {
            let e = DSHServerError.nodeMissing(probed: probed)
            lastError = e; finish(.failure(e)); return
        }
        resolvedNode = node
        NSLog("[DSH] resolved node = %@", node.path)

        // ---- 2. 体检（四项硬前提）
        let pr = NodeProbe.fullCheck(node: node)
        probe = pr
        guard pr.ok else {
            let e = DSHServerError.probeFailed(pr)
            lastError = e; finish(.failure(e)); return
        }

        // ---- 3. 引擎文件
        let cli = DSHPaths.dshCli
        guard fm.fileExists(atPath: cli.path) else {
            let e = DSHServerError.engineMissing
            lastError = e; finish(.failure(e)); return
        }

        killStale()

        // ---- 4. 起进程
        let p = Process()
        p.executableURL = node
        p.arguments = [
            "--expose-internals",
            "--predictable",         // W^X 权限翻转的确定性前提
            "--single-threaded",      // mprotect flip 是进程级的，必须单线程
            cli.path,
            "web", "--no-open",
            "--port", String(port),
        ]
        p.currentDirectoryURL = DSHPaths.workspace
        p.environment = buildEnv(node: node)

        // 日志：截断后重定向
        fm.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.truncateFile(atOffset: 0)
            fh.seekToEndOfFile()
            p.standardOutput = fh
            p.standardError = fh
        }

        p.terminationHandler = { proc in
            self.ready = false; self.proc = nil
            NSLog("[DSH] engine exited code=\(proc.terminationStatus)")
        }

        do { try p.run() } catch {
            let e = DSHServerError.spawnFailed(error.localizedDescription)
            lastError = e; finish(.failure(e)); return
        }
        proc = p
        NSLog("[DSH] engine pid=\(p.processIdentifier)")

        // ---- 5. 等 token
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if !p.isRunning {
                let e = DSHServerError.exited(code: p.terminationStatus)
                lastError = e; finish(.failure(e)); return
            }
            if let tok = scrapeToken() {
                token = tok; ready = true; lastError = nil
                if let u = currentURL() { finish(.success(u)); return }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        let e = DSHServerError.timeout
        lastError = e; finish(.failure(e))
    }

    /// 引擎启动后会把带 token 的 URL 打进 stdout；日志文件里找它。
    private func scrapeToken() -> String? {
        guard let txt = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        for line in txt.split(separator: "\n").reversed() {
            guard let r = line.range(of: "token=") else { continue }
            let rest = line[r.upperBound...]
            let tok = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            if tok.count >= 16 { return String(tok) }
        }
        return nil
    }

    private func buildEnv(node: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = DSHPaths.documents.path
        env["TMPDIR"] = NSTemporaryDirectory()
        env["DSH_HOME"] = DSHPaths.home.path
        env["DSH_PERMISSION_MODE"] = Settings.shared.permissionMode
        // PATH 里把 node 自己所在目录放最前，避免引擎内部再调 PATH 里的 node 时命中 wrapper
        env["PATH"] = node.deletingLastPathComponent().path
            + ":/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
        if let k = Settings.shared.apiKey, !k.isEmpty { env["DEEPSEEK_API_KEY"] = k }
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    private func killStale() {
        if let p = proc, p.isRunning { p.terminate(); p.waitUntilExit() }
        proc = nil; ready = false; token = ""
    }

    func stop() { killStale() }
}