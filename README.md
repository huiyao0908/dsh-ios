# DSH for iOS — 构建与安装

产出：`DSH.ipa`（未签名），用 AppSync Unified 装到已越狱 iPhone。

## 目录

```
iosport/
├─ .github/workflows/build.yml          两段式 CI：先编 Node，再打 IPA
├─ node-build/
│  ├─ build-node-ios.sh                 交叉编译 arm64-apple-ios 的真 Node（方案 A1）
│  └─ verify-node-ios.sh                在设备上验证 child_process / spawn 能力面
├─ shims/
│  ├─ apply-ios-shims.sh                就地给引擎打 shim（幂等）
│  ├─ node-pty-ios.js                   node-pty 的 iOS 实现（posix_spawn 冒充 PTY）
│  └─ patches/0001-platform-normalize.patch
├─ app/
│  ├─ DSH.entitlements                  越狱提权 entitlements
│  └─ DSH/                              Swift 三 Tab 壳
│     ├─ DSHApp.swift                   入口 + Tab 装配
│     ├─ ChatViewController.swift       对话 Tab（WKWebView → 127.0.0.1:43129）
│     ├─ EnvironmentViewController.swift 环境 Tab（诊断 + 一键安装 + 日志）
│     ├─ SettingsViewController.swift   设置 Tab
│     ├─ DSHServer.swift                引擎进程守护
│     ├─ DSHPaths.swift                 沙箱路径
│     └─ Settings.swift                 UserDefaults 持久化
├─ scripts/build-ipa.sh                 组装 + 签名 + 打 IPA
└─ engine/                              app.asar 抽出的引擎（111.7MB，11435 文件）
```

## 三条必须打的 iOS shim

| # | 目标 | 症状（不打则） |
|---|---|---|
| 1 | `dsh-subprocess-local` 的 `process.platform` 归一化 `ios`→`darwin` | 启动即抛 `subprocess-local: terminal inspection is unsupported on platform ios` |
| 2 | koffi 加载拦截 | POSIX 上加载 win32 FFI，`Cannot find module './win32_x64/koffi.node'` 被 agent-loop 静默吞掉 |
| 3 | `node-pty` 换成 posix_spawn 实现 | 终端相关功能报模块缺失 |

## 两条编译路线

### A1（主路线）— 自编真 Node

复用 nodejs-mobile 的 iOS 交叉编译管线，但**剥掉它的 mobile cripple 补丁**。

| 补丁 | 必须剥掉的原因 |
|---|---|
| `child_process`/`cluster` 禁用 | dsh 的 subprocess 层、tool-bash、job、terminal、插件安装全走 spawn |
| `os.platform()` 改返 `'ios'` | 引擎 `createProcessInspector` 只认 `'darwin'`，否则启动即抛 |
| `process.exit()` 改写 / WASM 禁用 | 越狱机不受 App Store 规则约束 |

为什么越狱 iOS 能 spawn：Apple 的限制来自 App Store 审核 + amfi 签名校验，**不是内核**。
palera1n rootless 已关闭 amfi 校验，且本 App 以未签名 IPA 安装。
被 spawn 的子进程二进制必须已签名（`ldid -S`）。

### A2（备份路线）— 找现成 iOS arm64 Node

1. Sileo 里逐个加这些源，再搜 `node` / `nodejs` / `node-ios`：
   - `https://byg.iosios.net/`（搬运工源）
   - `https://apt.25mao.com/`（猫源）
   - `https://repo.snailovet.com/`（蜗牛源）
   - `https://yttxcs.com/`
   - `https://apt.cydia.pro/`
   - `https://havoc.app/`
2. 找到 deb 后 `dpkg -i` 装到 `/var/jb/usr/bin/node`。
3. `DSHServer.buildEnv()` 的 PATH 已含 `/var/jb/usr/bin`；
   改 `DSHPaths.nodeBinary` 指向该路径即可，不需要 A1 的交叉编译。

## 本地验证（Windows，不需要 Mac）

引擎层已在 Windows 上用 Node 22 跑通过完整 RPC 往返（含真实模型回话）。
shim 脚本的语法与幂等性可在此先验证：

```powershell
Copy-Item -Recurse _iosport\engine _iosport\engine-shim-test
bash iosport/shims/apply-ios-shims.sh _iosport/engine-shim-test
```

## 安装到 iPhone 8

1. GitHub Actions 跑完，下载 `DSH-ipa` artifact
2. 把 `DSH.ipa` 传到手机（AirDrop / Filza 局域网 / 文件共享）
3. Filza 里点开 → AppSync Unified 安装器装
4. 首次打开 → 「环境」Tab → 一键安装 → 「设置」Tab 填 API Key

## 已知限制

- 只能装已越狱设备（iPhone 8 / iOS 16.6 / rootless palera1n）
- 未越狱设备、iOS 27 那台：装不上
- 终端没有真 PTY（iOS 无 `/dev/ptmx`），shell 无行编辑 / Tab 补全
- WASM 不可用（iOS 禁 JIT）
- Office 导出（libreoffice 182MB）、语音（sherpa-onnx 22MB）、图像（sharp 19MB）、ripgrep（5MB）已裁剪