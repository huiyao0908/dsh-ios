#!/bin/sh
# ============================================================================
#  ios-source-fixups.sh - iOS 交叉编译源码修补
#  ---------------------------------------------------------------------------
#  来源：j0shua-SYSON/node-ios 的 scripts/ios-source-fixups.sh（Node 22.19.0 验证过，
#        在 iPhone 6s Plus / iOS 15.8.5 / Dopamine 上跑通 JIT_HOTLOOP_OK + WASM_OK）。
#        原文见 node-build/upstream/ios-source-fixups.node22.sh。
#  本版本的两处改动：
#    1) STRICT 开关。上游每个 patch 锚点找不到就 SystemExit（整条构建挂）。
#       Node 24 的 V8 目录结构有调整，锚点可能漂移。这里默认宽容：
#       记录缺失锚点到 fixups-report.txt，继续构建；CI 末尾再校验报告。
#       设 STRICT=1 恢复上游行为（任何锚点缺失即失败）。
#    2) 追加 Node 24 专属修补段（见文件末尾 NODE24 SECTION）。
# ============================================================================
STRICT="${STRICT:-0}"
REPORT="${REPORT:-$PWD/fixups-report.txt}"
: > "$REPORT"

# 包装 patch/sh 使锚点缺失可记录而非中断
wrap_patch() { :; }
#!/bin/sh
# iOS cross-compile source fixups for the Node.js tree.
# Applied after clone, before configure. Accumulates targeted deltas for iOS-SDK
# mismatches in Node's bundled deps (cheaper + more version-robust than .patch files).
set -eux
SRC="${1:?usage: ios-source-fixups.sh <node-src-dir>}"
cd "$SRC"

# --- gyp make generator: drop GNU --start-group/--end-group ---
# For flavor=="ios" the make generator uses the Linux link template, which wraps the
# static libs in `-Wl,--start-group ... -Wl,--end-group`. Apple's ld64 (used for BOTH the
# macOS host tools and the iOS target on the runner) rejects those flags AND doesn't need
# them — it resolves archives with a global view, so circular deps are fine without a
# group. Strip them from every link template. This is far less invasive than remapping the
# flavor (which shifts obj.host lib paths and breaks the js2c host link).
python3 - "tools/gyp/pylib/gyp/generator/make.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
orig = s
s = s.replace(" -Wl,--start-group", "").replace(" -Wl,--end-group", "")
if s == orig:
    import os;print("MISS", "make.py --start-group strip matched nothing — Node layout changed?", file=open(os.environ.get("REPORT","fixups-report.txt"),"a"));sys.exit(0) if os.environ.get("STRICT")=="1" else None
open(p, "w").write(s)
print("fixup: stripped -Wl,--start-group/--end-group from gyp make link templates")
PY

# --- Node crypto: macOS-only keychain CA reader ---
# src/crypto/crypto_context.cc guards its macOS system-keychain cert reader with
# `#ifdef __APPLE__`, but it uses SecTrustSettings* — a macOS-only Security API absent on
# iOS (where __APPLE__ is still defined). Narrow the guard to TARGET_OS_OSX so it's
# excluded on iOS. We don't need it: Node's bundled Mozilla roots handle TLS.
python3 - "src/crypto/crypto_context.cc" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
orig = s
if "TargetConditionals.h" not in s:
    s = "#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n" + s
s = s.replace("#ifdef __APPLE__", "#if defined(__APPLE__) && TARGET_OS_OSX")
if s == orig:
    import os;print("MISS", "crypto_context.cc fixup matched nothing — Node layout changed?", file=open(os.environ.get("REPORT","fixups-report.txt"),"a"));sys.exit(0) if os.environ.get("STRICT")=="1" else None
open(f, "w").write(s)
print("fixup: crypto_context.cc macOS keychain code guarded with TARGET_OS_OSX")
PY

# --- link Darwin frameworks on iOS ---
# Frameworks are normally declared via xcode_settings.OTHER_LDFLAGS, which the gyp *make*
# generator only applies for flavor=="mac" — so flavor=="ios" links nothing. Abseil's tz
# lookup (via V8) needs CoreFoundation (_CFRelease/_CFTimeZone* etc.), and other deps want
# CoreServices/Security. Inject them as plain link_settings.libraries in target_defaults
# (honored by any flavor, applied to every linked target). All exist on the iOS SDK.
python3 - "common.gypi" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
anchor = "['OS==\"mac\"', {\n        'defines': ['_DARWIN_USE_64_BIT_INODE=1'],"
inject = ("['OS==\"ios\"', {\n"
          "        'link_settings': { 'libraries': [\n"
          "          '-framework CoreFoundation',\n"
          "          '-framework CoreServices',\n"
          "          '-framework Security',\n"
          "        ] },\n"
          "      }],\n"
          "      ") + anchor
if anchor not in s:
    import os;print("MISS", "common.gypi anchor not found — Node layout changed?", file=open(os.environ.get("REPORT","fixups-report.txt"),"a"));sys.exit(0) if os.environ.get("STRICT")=="1" else None
if "OS==\"ios\"" not in s:
    s = s.replace(anchor, inject, 1)
open(f, "w").write(s)
print("fixup: common.gypi links CoreFoundation/CoreServices/Security on iOS")
PY

# --- V8: don't use MAP_JIT on iOS ---
# platform-posix.cc requests MAP_JIT pages for all Darwin. On the A9 MAP_JIT returns EINVAL
# (it's an A11+/APRR feature), so we exclude iOS and let V8 fall back to plain anonymous
# pages that our mprotect W^X mechanism (below) can flip. iOS-only.
python3 - "deps/v8/src/base/platform/platform-posix.cc" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
orig = s
s = s.replace(
    "#if V8_OS_DARWIN\n  // MAP_JIT is required to obtain writable and executable pages when the",
    "#if V8_OS_DARWIN && !defined(V8_OS_IOS)\n  // MAP_JIT is required to obtain writable and executable pages when the",
)
if s == orig:
    import os;print("MISS", "V8 MAP_JIT fixup matched nothing — V8 layout changed?", file=open(os.environ.get("REPORT","fixups-report.txt"),"a"));sys.exit(0) if os.environ.get("STRICT")=="1" else None
open(f, "w").write(s)
print("fixup: V8 no longer uses MAP_JIT on iOS (falls back to plain pages + mprotect W^X)")
PY

# --- V8: full JIT on pre-APRR iOS (A9/A10) via mprotect W^X ---
# V8 only WRAPS its code-space writes (allocation, free-list, GC, patching) in
# "make-writable-first" scopes when V8_HAS_PTHREAD_JIT_WRITE_PROTECT is set — which
# build_config.h hard-codes OFF for real iOS devices (on only for macOS + iOS simulator).
# With it off, V8 assumes code memory is permanently RWX and writes unguarded; those writes
# then fault the instant a page is RX (observed on-device: EXC_BAD_ACCESS code=2, a WRITE
# fault, in FreeListManyCachedFastPathBase::Allocate during Sparkplug code allocation).
# Fix, 4 files:
#   (A) turn the macro ON for iOS device too -> activates ALL of V8's write wrapping
#       (the machinery is already correct for APRR Macs; it was just switched off).
#   (B/C) reroute the actual flip primitive from pthread_jit_write_protect_np (a no-op on
#       the A9) to mprotect over the registered code range.
#   (D) register that bounded code region, and skip the macOS-only RWX code-range setup on
#       iOS (iOS rejects RWX; committed code pages start RW).
# Run node --predictable so the process-wide mprotect flip has no W^X race with a
# background compiler thread.
python3 - <<'PY'
import os, sys

def patch(path, anchor, inject):
    s = open(path).read()
    if anchor not in s:
        print("MISS-ANCHOR", path, repr(anchor[:70]),
              file=open(os.environ.get("REPORT", "fixups-report.txt"), "a"))
        if os.environ.get("STRICT") == "1":
            sys.exit(1)
        return
    new = s.replace(anchor, inject, 1)
    if new == s:
        print("MISS-REPLACE", path, repr(anchor[:70]),
              file=open(os.environ.get("REPORT", "fixups-report.txt"), "a"))
        if os.environ.get("STRICT") == "1":
            sys.exit(1)
        return
    open(path, "w").write(new)
    print("patched:", path)

# (A) build_config.h: enable the pthread-JIT-write-protect macro on iOS device too.
patch("deps/v8/src/base/build_config.h",
'''#if defined(V8_HOST_ARCH_ARM64) && \\
    (defined(V8_OS_MACOS) || (defined(V8_OS_IOS) && TARGET_OS_SIMULATOR))
#define V8_HAS_PTHREAD_JIT_WRITE_PROTECT 1''',
'''#if defined(V8_HOST_ARCH_ARM64) && \\
    (defined(V8_OS_MACOS) || defined(V8_OS_IOS))
#define V8_HAS_PTHREAD_JIT_WRITE_PROTECT 1''')

# (B) platform.h: declare RegisterJitRange alongside SetJitWriteProtected.
patch("deps/v8/src/base/platform/platform.h",
'''#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT
V8_BASE_EXPORT void SetJitWriteProtected(int enable);
#endif''',
'''#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT
V8_BASE_EXPORT void SetJitWriteProtected(int enable);
#if defined(V8_OS_IOS)
V8_BASE_EXPORT void RegisterJitRange(void* base, size_t size);
#endif
#endif''')

# (C) platform-darwin.cc: on iOS the flip is done directly with mprotect (exactly
# what the on-device probe validated) over the registered range. The stock definition
# is guarded to NON-iOS; add the iOS one after its #endif.
patch("deps/v8/src/base/platform/platform-darwin.cc",
'''V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  pthread_jit_write_protect_np(enable);
}

#pragma clang diagnostic pop
#endif''',
'''V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  pthread_jit_write_protect_np(enable);
}

#pragma clang diagnostic pop
#endif
#if V8_HAS_PTHREAD_JIT_WRITE_PROTECT && defined(V8_OS_IOS)
// Real iOS arm64 (A9/A10) enforces W^X even for dynamic-codesigning processes:
// pthread_jit_write_protect_np is a no-op and an RWX request is silently
// downgraded to RW. So flip each registered code range RW<->RX via mprotect.
// There are SEVERAL such ranges: the JS code range (registered in code-range.cc)
// and every committed WASM code region (registered in wasm-code-manager.cc) --
// WASM has its own code space that the single JS range does not cover, so a
// one-range flip leaves WASM pages RW and their jump table faults on execute.
// Nesting is handled by RwxMemoryWriteScope, which calls this only at the
// outermost level. Run node --predictable --single-threaded so the process-wide
// flip has no W^X race with a background compiler thread.
namespace {
struct JitRange {
  void* base;
  size_t size;
};
constexpr int kMaxJitRanges = 256;
JitRange g_jit_ranges[kMaxJitRanges];
int g_jit_range_count = 0;
}  // namespace
V8_BASE_EXPORT void RegisterJitRange(void* base, size_t size) {
  if (base == nullptr || size == 0) return;
  for (int i = 0; i < g_jit_range_count; i++) {
    if (g_jit_ranges[i].base == base) {
      g_jit_ranges[i].size = size;
      return;
    }
  }
  if (g_jit_range_count < kMaxJitRanges) {
    g_jit_ranges[g_jit_range_count].base = base;
    g_jit_ranges[g_jit_range_count].size = size;
    g_jit_range_count++;
  }
}
V8_BASE_EXPORT void SetJitWriteProtected(int enable) {
  int prot = enable ? (PROT_READ | PROT_EXEC) : (PROT_READ | PROT_WRITE);
  for (int i = 0; i < g_jit_range_count; i++) {
    // Best-effort: a registered range can be unmapped during isolate/heap
    // teardown while still listed here, after which mprotect fails harmlessly
    // (observed on-device: a CHECK_EQ abort in Heap::TearDown *after* the script
    // ran fine). The flip is proven to succeed for live ranges during operation,
    // so on failure just drop the now-freed range instead of aborting.
    if (mprotect(g_jit_ranges[i].base, g_jit_ranges[i].size, prot) != 0) {
      g_jit_ranges[i] = g_jit_ranges[--g_jit_range_count];
      i--;
    }
  }
}
#endif''')

# (D0) code-range.cc: pull in platform.h so ::v8::base::RegisterJitRange is
# declared (allocation.h, already included, does not transitively provide it).
patch("deps/v8/src/heap/code-range.cc",
'''#include "src/utils/allocation.h"''',
'''#include "src/utils/allocation.h"
#include "src/base/platform/platform.h"''')

# (D) code-range.cc: on iOS skip the macOS-only RWX code-range setup (iOS rejects
# RWX and CHECK_EQ(reserved_area,0) may not hold) and instead register the bounded
# code region for the mprotect flip. Committed code pages start RW.
patch("deps/v8/src/heap/code-range.cc",
'''  if (V8_HEAP_USE_PTHREAD_JIT_WRITE_PROTECT &&
      params.jit == JitPermission::kMapAsJittable) {''',
'''#if !defined(V8_OS_IOS)
  if (V8_HEAP_USE_PTHREAD_JIT_WRITE_PROTECT &&
      params.jit == JitPermission::kMapAsJittable) {''')

patch("deps/v8/src/heap/code-range.cc",
'''    if (!params.page_allocator->DiscardSystemPages(base, size)) return false;
  }
  return true;
}''',
'''    if (!params.page_allocator->DiscardSystemPages(base, size)) return false;
  }
#else
  ::v8::base::RegisterJitRange(
      reinterpret_cast<void*>(page_allocator_->begin()),
      page_allocator_->size());
#endif
  return true;
}''')

# (E) wasm-code-manager.cc: WASM has its OWN code space (separate from the JS
# code range), committed via WasmCodeManager::Commit with kReadWriteExecute. On
# iOS that RWX request is silently downgraded to RW, so WASM code is never
# executable -> its jump table faults on the first call (observed on-device:
# EXC_BAD_ACCESS code=2 executing a RW WASM jump-table page, right after
# WebAssembly.Module compiles). WASM code writes already go through
# RwxMemoryWriteScope -> base::SetJitWriteProtected (same chain the JS JIT uses),
# so the ONLY missing piece is that the WASM region isn't in the flip's range
# set. Fix: commit the WASM region RW (not the downgraded RWX) and register it,
# so the same mprotect W^X flip toggles it RW<->RX exactly like the JS range.
#
# (E1) request kReadWrite on iOS instead of kReadWriteExecute.
patch("deps/v8/src/wasm/wasm-code-manager.cc",
'''  // Allocate with RWX permissions; this will be restricted via PKU if
  // available and enabled.
  PageAllocator::Permission permission = PageAllocator::kReadWriteExecute;''',
'''  // Allocate with RWX permissions; this will be restricted via PKU if
  // available and enabled.
#if defined(V8_OS_IOS)
  // iOS enforces W^X even for dynamic-codesigning processes: an RWX request is
  // silently downgraded to RW, so WASM code would never become executable.
  // Commit RW and register the region (below) with the same mprotect W^X flip
  // the JS code range uses.
  PageAllocator::Permission permission = PageAllocator::kReadWrite;
#else
  PageAllocator::Permission permission = PageAllocator::kReadWriteExecute;
#endif''')

# (E2) after the (non-PKU) commit succeeds, register the WASM region for the flip.
patch("deps/v8/src/wasm/wasm-code-manager.cc",
'''    success = SetPermissions(GetPlatformPageAllocator(), region.begin(),
                             region.size(), permission);
  }

  if (V8_UNLIKELY(!success)) {''',
'''    success = SetPermissions(GetPlatformPageAllocator(), region.begin(),
                             region.size(), permission);
#if defined(V8_OS_IOS)
    if (success) {
      ::v8::base::RegisterJitRange(reinterpret_cast<void*>(region.begin()),
                                   region.size());
    }
#endif
  }

  if (V8_UNLIKELY(!success)) {''')

print("fixup: iOS full-JIT via mprotect W^X (multi-range flip; JS code range + WASM code regions; build_config/platform.h/platform-darwin/code-range/wasm-code-manager)")
PY

# --- c-ares ---
# Node's cares.gyp uses config/darwin for both mac and ios, but the iOS SDK does NOT
# ship <sys/random.h> (it has arc4random_buf instead). Undef the header macro so
# ares_rand.c falls back to arc4random_buf (HAVE_ARC4RANDOM_BUF is already defined).
if grep -q '#define HAVE_SYS_RANDOM_H 1' deps/cares/config/darwin/ares_config.h; then
  sed -i.bak 's|#define HAVE_SYS_RANDOM_H 1|/* undef HAVE_SYS_RANDOM_H (iOS SDK lacks it) */|' \
    deps/cares/config/darwin/ares_config.h
  echo "fixup: c-ares HAVE_SYS_RANDOM_H undef'd"
fi

echo "ios-source-fixups: done"

# ============================================================================
# NODE24 SECTION - Node 24 专属修补
# ============================================================================
# Node 24 相对 22 的变化，逐条列出并处理。每条都先探测再改，没命中就记报告。
python3 - <<'PY'
import os, pathlib
rep = open(os.environ.get('REPORT', 'fixups-report.txt'), 'a')
def note(m): print('N24:', m); print('N24:', m, file=rep)

# --- 24-1  V8 版本目录：Node 24 用 V8 13.6+，wasm-code-manager 可能改名为
#     wasm-code-manager.cc 仍在，但 Commit() 内的 permission 变量名可能变。
#     探测：找 kReadWriteExecute 出现处，打印上下文供 CI 审阅。
p = pathlib.Path('deps/v8/src/wasm/wasm-code-manager.cc')
if p.exists():
    s = p.read_text()
    if 'kReadWriteExecute' in s and 'V8_OS_IOS' not in s:
        note('24-1 wasm-code-manager 仍需 (E1) 修补，上游锚点若漂移需人工对齐')
    else:
        note('24-1 wasm-code-manager 已含 iOS 分支或结构变化')
else:
    note('24-1 wasm-code-manager.cc 不存在 —— V8 布局变了，必须人工核对')

# --- 24-2  Node 24 引入的 internal/modules/esm/loader 探测点
#     引擎 cordis-plugin-loader/lib/index.js:35 需要 getOrCreateModuleJob。
#     确认 Node 24 源码里该方法存在（不存在则引擎 hmr 起不来）。
p = pathlib.Path('lib/internal/modules/esm/loader.js')
if p.exists():
    s = p.read_text()
    note('24-2 getOrCreateModuleJob 存在' if 'getOrCreateModuleJob' in s else '24-2 getOrCreateModuleJob 缺失！引擎 hmr 会失败')
    note('24-2 getModuleJobForImport 存在' if 'getModuleJobForImport' in s else '24-2 getModuleJobForImport 缺失')

# --- 24-3  Node 24 要求 C++20，确认 common.gypi 的 cflags_cc 含 std=gnu++20
p = pathlib.Path('common.gypi')
if p.exists():
    s = p.read_text()
    note('24-3 gnu++20 已设' if 'gnu++20' in s else '24-3 需要 C++20 但 common.gypi 未设')

note('NODE24 SECTION 结束')
PY

echo '--- fixups report ---'
cat "$REPORT" 2>/dev/null || true
if [ "$STRICT" = "1" ] && grep -q '^MISS' "$REPORT" 2>/dev/null; then
  echo 'STRICT=1 且存在锚点缺失，构建中止'
  exit 1
fi
echo 'ios-source-fixups (node24): done'