#!/usr/bin/env bash
# 在 unpacked engine 上就地应用 iOS shim。幂等：重复跑不会重复插入。
set -euo pipefail
ENGINE="${1:?usage: apply-ios-shims.sh <engine-dir>}"
NM="$ENGINE/dsh/node_modules"
[ -d "$NM" ] || { echo "engine layout wrong: $NM"; exit 1; }
say(){ printf '\033[1;35m[shim]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# SHIM 1  subprocess-local: process.platform === 'ios' -> 'darwin'
#   症状若不打：启动后工具调用报
#     subprocess-local: terminal inspection is unsupported on platform ios
# ---------------------------------------------------------------------------
S1="$NM/@deepseek-ai/dsh-subprocess-local/lib"
if [ -d "$S1" ]; then
  if grep -rqs 'dsh-ios-shim:platform' "$S1"; then
    say 'S1 already applied'
  else
    say 'S1 patching subprocess-local'
    python3 - "$S1" <<'PYEOF'
import sys, pathlib, re
root = pathlib.Path(sys.argv[1])
helper = '''
// dsh-ios-shim:platform - iOS 的 Node 报 process.platform === 'ios'，
// 而引擎只认 'darwin'。Darwin 内核接口在 iOS 上一致，映射过去即可。
function __dshNormalizePlatform(p) {
\tif (p === "ios" || p === "iphoneos" || p === "iphonesimulator") return "darwin";
\treturn p;
}
const __dshPlatformDesc = Object.getOwnPropertyDescriptor(process, "platform");
if (__dshPlatformDesc && __dshPlatformDesc.value !== "darwin") {
\ttry { Object.defineProperty(process, "platform", { ...__dshPlatformDesc, value: "darwin" }); } catch (e) {}
}
'''
n = 0
for f in root.rglob('*.js'):
    s = f.read_text(encoding='utf-8', errors='surrogateescape')
    if '__dshNormalizePlatform' in s:
        continue
    orig = s
    s = re.sub(r'function createProcessInspector\(platform = process\.platform, arch = process\.arch, internals = DEFAULT_INTERNALS\) \{',
               'function createProcessInspector(platform = process.platform, arch = process.arch, internals = DEFAULT_INTERNALS) {\n\tplatform = __dshNormalizePlatform(platform);',
               s, count=1)
    s = re.sub(r'throw new Error\(`subprocess-local: terminal inspection is unsupported on platform \$\{platform\}`\);',
               'return new MacProcessInspector(internals); // dsh-ios-shim:platform', s, count=1)
    if s != orig:
        s = helper + '\n' + s
        f.write_text(s, encoding='utf-8', errors='surrogateescape')
        n += 1
        print('  patched', f)
print('  files:', n)
PYEOF
  fi
fi

# ---------------------------------------------------------------------------
# SHIM 2  koffi 兜底拦截：POSIX 上永远不该加载 win32 FFI
# ---------------------------------------------------------------------------
say 'SHIM 2 koffi guard'
python3 - "$NM" <<'PYEOF'
import sys, pathlib
nm = pathlib.Path(sys.argv[1])
guard = '''
// dsh-ios-shim:koffi - POSIX 上绝不应该加载 win32 FFI。
(function __dshKoffiGuard() {
\tif (process.platform !== "win32") {
\t\ttry {
\t\t\tconst Module = require("node:module");
\t\t\tconst origResolve = Module._resolveFilename;
\t\t\tconst BLOCK = /[\\\\/]koffi(?:\\.[a-z0-9]+)?$/i;
\t\t\tModule._resolveFilename = function (request) {
\t\t\t\tif (BLOCK.test(String(request))) {
\t\t\t\t\tconst e = new Error("[dsh-ios-shim] koffi is win32-only; refused on " + process.platform);
\t\t\t\t\te.code = "ERR_DSH_KOFFI_ON_POSIX";
\t\t\t\t\tthrow e;
\t\t\t\t}
\t\t\t\treturn origResolve.apply(this, arguments);
\t\t\t};
\t\t} catch (e) {}
\t}
})();
'''
for sub in ('@deepseek-ai/dsh-subprocess-local', '@deepseek-ai/dsh-fs-local',
            '@deepseek-ai/dsh-session-persistence-jsonl'):
    d = nm / sub / 'lib'
    if not d.is_dir():
        continue
    for f in d.rglob('*.js'):
        s = f.read_text(encoding='utf-8', errors='surrogateescape')
        if '__dshKoffiGuard' in s:
            continue
        f.write_text(guard + '\n' + s, encoding='utf-8', errors='surrogateescape')
        print('  koffi-guard ->', f)
PYEOF

say 'apply-ios-shims done'