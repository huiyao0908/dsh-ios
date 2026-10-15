//  NodeProbe.swift - Node 运行时体检
//  ---------------------------------------------------------------------------
//  为什么要有这个：iPhone 上装的 Node 来源五花八门（Sileo 源 / 手工 deb / 我们自编），
//  而且 Sileo 装包会往 PATH 里放 wrapper，给每个 node 调用追加一串 V8 不认的参数：
//    /var/jb/usr/local/lib/nodejs/node: bad option:
    --no-wasm-code-gc --no-opt --no-sparkplug --single-threaded --liftoff --no-wasm-tier-up
//  所以必须：① 走绝对路径 ② 启动前逐项体检 ③ 把结果写日志给「环境」页显示。
//
//  体检四项，全部是「能不能跑 dsh 引擎」的硬前提：
//    1. --version            → 能不能启动（签名有效、依赖齐全）
//    2. process.versions.v8  → V8 版本（判断 JIT / 特性）
//    3. require('child_process') → 能不能 spawn（dsh subprocess 层的地基）
//    4. spawn 一次真实命令   → spawn 真的能用（不只是模块能加载）
//  第 4 项是判决书：只要它能打印出东西，dsh 的核心能力就成立。
import Foundation

enum NodeProbe {

    struct Result {
        var nodePath: String = ""
        var version: String = ""
        var v8: String = ""
        var hasChildProcess = false
        var spawnWorks = false
        var spawnOutput: String = ""
        var failures: [String] = []
        var rawLog: String = ""
        var ok: Bool { failures.isEmpty && spawnWorks }
    }

    /// 跑 `<node> <args>`，返回 (exitCode, stdout+stderr)。超时 15s。
    @discardableResult
    static func exec(_ node: URL, _ args: [String], timeout: TimeInterval = 15) -> (Int32, String) {
        let p = Process()
        p.executableURL = node
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = DSHPaths.documents.path
        env["TMPDIR"] = NSTemporaryDirectory()
        // 关键：把 node 自己所在目录放 PATH 最前，避免命中 Sileo 的 wrapper
        env["PATH"] = node.deletingLastPathComponent().path + ":/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/bin"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        do { try p.run() } catch { return (-1, "spawn failed: \(error.localizedDescription)") }

        // 超时看门狗
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning { p.terminate(); return (-2, "timeout after \(Int(timeout))s") }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    /// 只取版本号，用于 resolveNode() 的快速筛选。
    static func runVersion(_ node: URL) -> String? {
        let (code, out) = exec(node, ["--version"], timeout: 8)
        guard code == 0 else { return nil }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("v") ? t : nil
    }

    /// 完整体检，写日志到 DSHPaths.probeLog。
    static func fullCheck(node: URL) -> Result {
        var r = Result()
        r.nodePath = node.path
        var log: [String] = []
        func note(_ s: String) { log.append(s); NSLog("[NodeProbe] %@", s) }

        note("node: \(node.path)")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: node.path) else {
            r.failures.append("文件不存在或不可执行")
            note("FAIL 文件不存在或不可执行")
            r.rawLog = log.joined(separator: "\n"); write(log); return r
        }
        note("OK 可执行位已设")

        // 1. --version
        let (c1, o1) = exec(node, ["--version"])
        if c1 == 0 {
            r.version = o1.trimmingCharacters(in: .whitespacesAndNewlines)
            note("OK --version → \(r.version)")
        } else {
            r.failures.append("--version 失败(exit \(c1)): \(o1.prefix(200))")
            note("FAIL --version exit=\(c1) :: \(o1.prefix(200))")
        }

        // 2. V8 版本（顺带看进程能不能真正执行 JS）
        let (c2, o2) = exec(node, ["-e", "process.stdout.write(process.versions.v8)"])
        if c2 == 0 { r.v8 = o2.trimmingCharacters(in: .whitespacesAndNewlines); note("OK v8=\(r.v8)") }
        else { note("WARN v8 探测失败 exit=\(c2) :: \(o2.prefix(200))") }

        // 3. child_process 模块
        let (c3, o3) = exec(node, ["-e", "require('child_process');process.stdout.write('CP_OK')"])
        if c3 == 0 && o3.contains("CP_OK") {
            r.hasChildProcess = true; note("OK child_process 可加载")
        } else {
            r.failures.append("child_process 不可用: \(o3.prefix(200))")
            note("FAIL child_process exit=\(c3) :: \(o3.prefix(200))")
        }

        // 4. 真实 spawn（判决书）
        let js = "const{execSync}=require('child_process');" +
                 "const o=execSync('echo DSH_SPAWN_OK').toString();" +
                 "process.stdout.write(o)"
        let (c4, o4) = exec(node, ["-e", js])
        if c4 == 0 && o4.contains("DSH_SPAWN_OK") {
            r.spawnWorks = true
            r.spawnOutput = o4.trimmingCharacters(in: .whitespacesAndNewlines)
            note("OK spawn 真实可用 → \(r.spawnOutput)")
        } else {
            r.failures.append("spawn 不可用(exit \(c4)): \(o4.prefix(300))")
            note("FAIL spawn exit=\(c4) :: \(o4.prefix(300))")
        }

        // 5. iOS 无 /dev/ptmx 的确认（不影响结论，只记录）
        let (_, o5) = exec(node, ["-e", "try{require('fs').accessSync('/dev/ptmx');process.stdout.write('PTMX_YES')}catch(e){process.stdout.write('PTMX_NO')}"])
        note(o5.contains("PTMX_YES") ? "INFO /dev/ptmx 存在" : "INFO /dev/ptmx 不存在（预期；已用 posix_spawn shim）")

        note(r.ok ? "=== 体检通过，可以启动引擎 ===" : "=== 体检未通过：\(r.failures.joined(separator: " / ")) ===")
        r.rawLog = log.joined(separator: "\n")
        write(log)
        return r
    }

    private static func write(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: DSHPaths.logs, withIntermediateDirectories: true)
        if let d = text.data(using: .utf8) {
            try? d.write(to: DSHPaths.probeLog)   // 每次覆盖，环境页读的就是最新一次
        }
    }
}