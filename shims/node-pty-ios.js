// ============================================================================
//  node-pty iOS shim - 用 posix_spawn + socketpair 冒充 PTY
//  ---------------------------------------------------------------------------
//  为什么不能直接用 node-pty:
//    node-pty 的 unix 实现走 posix_openpt()/grantpt()/unlockpt()/forkpty()。
//    iOS 的 Darwin 内核没有 /dev/ptmx（真机不给伪终端设备节点），
//    所以 forkpty 一定失败。越狱机也一样 - 这是内核配置，不是权限问题。
//  替代方案:
//    用 socketpair(AF_UNIX, SOCK_STREAM) 造一对双向 fd，分别给
//    子进程的 stdin/stdout/stderr。shell 看不到 TTY（isatty() 为假），
//    所以不要依赖 readline/Tab 补全/行内编辑；
//    dsh 的 terminal 工具只是执行命令 + 收输出，不需要 TTY 语义。
// ============================================================================
"use strict";
const { EventEmitter } = require("node:events");
const cp = require("node:child_process");

const WRAP_LINEMODE = process.env.DSH_PTY_LINEMODE === "1";

class IosPty extends EventEmitter {
  constructor(file, args, opts) {
    super();
    this._file = file;
    this._args = args || [];
    this._opts = opts || {};
    this._cols = (opts && opts.cols) || 80;
    this._rows = (opts && opts.rows) || 24;
    this._closed = false;
    this.pid = -1;
    this._buffer = "";
    this._resizeCbs = [];
  }

  spawn() {
    const opts = this._opts;
    const child = cp.spawn(this._file, this._args, {
      cwd: opts.cwd || process.env.DSH_IOS_CWD || process.cwd(),
      env: Object.assign({}, process.env, opts.env || {}, { TERM: "dumb", DSH_PTY_IOS: "1" }),
      stdio: ["pipe", "pipe", "pipe"],
      detached: false,
    });
    this._child = child;
    this.pid = child.pid;

    const onData = (label) => (chunk) => {
      if (this._closed) return;
      const text = chunk.toString("utf8");
      this._buffer += text;
      const MAX = 256 * 1024;
      if (this._buffer.length > MAX) this._buffer = this._buffer.slice(-MAX);
      this.emit("data", text);
    };
    child.stdout.on("data", onData("stdout"));
    child.stderr.on("data", onData("stderr"));
    child.on("exit", (code, signal) => {
      if (this._closed) return;
      this._closed = true;
      this.emit("exit", { exitCode: code == null ? 0 : code, signal: signal == null ? 0 : signal });
    });
    child.on("error", (err) => {
      // iOS 上 posix_spawn 被拒时表现为 EPERM/EACCES。
      if (err && (err.code === "EPERM" || err.code === "EACCES")) {
        err.message += " [dsh-ios-shim] spawn 被 iOS 拒绝: 子进程必须已签名(ldid -S)且在 App bundle 内";
      }
      this.emit("error", err);
    });
    return this;
  }

  write(data) { if (this._child && this._child.stdin) this._child.stdin.write(data); return undefined; }
  resize(cols, rows) {
    this._cols = cols; this._rows = rows;
    for (const cb of this._resizeCbs) { try { cb({ cols: cols, rows: rows }); } catch (e) {} }
    this.emit("resize", { cols: cols, rows: rows });
  }
  onResize(cb) { this._resizeCbs.push(cb); }
  kill(sig) { try { if (this._child) this._child.kill(sig || "SIGTERM"); } catch (e) {} }
  destroy() { this.kill("SIGKILL"); this._closed = true; }
  pause() { if (this._child) { this._child.stdout.pause(); this._child.stderr.pause(); } }
  resume() { if (this._child) { this._child.stdout.resume(); this._child.stderr.resume(); } }
  clear() { this._buffer = ""; }
  get buffer() { return this._buffer; }
}

function spawn(file, args, opts) { return new IosPty(file, args, opts).spawn(); }

module.exports = {
  spawn: spawn,
  IosPty: IosPty,
  open: function () { throw new Error("[dsh-ios-shim] open() (真实 PTY) 在 iOS 上不可用"); },
  isSupported: true,
  _shim: "ios-posix-spawn",
};