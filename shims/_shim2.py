import sys, pathlib
nm = pathlib.Path(sys.argv[1])
guard = '''
// dsh-ios-shim:koffi - POSIX 上绝不应该加载 win32 FFI。
// 引擎本身已做懒加载；这里兜底，把 require 换成清晰可诊断的错误，
// 免得 agent-loop 的 catch 又一次把它静默吞掉。
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
        print('  skip (no dir)', sub)
        continue
    for f in d.rglob('*.js'):
        s = f.read_text(encoding='utf-8', errors='surrogateescape')
        if '__dshKoffiGuard' in s:
            continue
        f.write_text(guard + '\n' + s, encoding='utf-8', errors='surrogateescape')
        print('  koffi-guard ->', f)