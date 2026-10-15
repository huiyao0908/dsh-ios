import sys, pathlib, re
root = pathlib.Path(sys.argv[1])
helper = '''
// dsh-ios-shim:platform - iOS 上 process.platform === 'ios'，而引擎只认 'darwin'。
// Darwin 内核接口（libproc / proc_pidinfo / sysctl）在 iOS 上一致，且
// MacProcessInspector 不加载任何原生模块，直接映射过去。
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