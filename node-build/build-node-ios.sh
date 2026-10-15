#!/usr/bin/env bash
# ============================================================================
#  build-node-ios.sh — 为 iOS arm64 (越狱) 交叉编译真 Node.js
#  策略 A1: 复用 nodejs-mobile 的交叉编译管线, 但剥掉它的 "mobile cripple" 补丁
#  ---------------------------------------------------------------------------
#  必须保留的 nodejs-mobile 能力 (iOS 上真机可用的部分):
#    - arm64-apple-ios 交叉编译工具链设定
#    - iOS SDK 头文件/链接参数 (CoreFoundation, Security, UIKit)
#    - 关闭 intl / inspector (iOS 上本来没意义)
#  必须剥掉的补丁 (否则 dsh 跑不起来):
#    - child_process / cluster 禁用              -> dsh subprocess 层直接崩
#    - os.platform()/process.platform 返 'ios'   -> 引擎 createProcessInspector 抛异常
#    - process.exit() 改写                       -> 越狱机不需要守 App Store 规则
#    - WASM 禁用                                 -> 无必要
#  ---------------------------------------------------------------------------
#  为什么在越狱 iOS 上 fork/spawn 可行:
#    Apple 的限制来自 App Store 审核 + amfi 代码签名, 不是内核。
#    越狱机 (palera1n rootless) 已关闭 amfi 校验, 且 DSH 以 dpkg 装的
#    未签名 IPA 形式安装 (AppSync Unified), 因此 posix_spawn 一个躺在
#    App bundle 内、已由我们签名的可执行文件是允许的。
#    注意: 被 spawn 的子进程必须也带有效签名 (用 ldid 签 or adhoc 签)。
# ============================================================================
set -euo pipefail

NODE_TAG="${NODE_TAG:-}"
NODE_MAJOR="${NODE_MAJOR:-22}"
NODE_VERSION="${NODE_VERSION:-22.9.0}"
NMB_REF="${NMB_REF:-main}"
IOS_MIN="${IOS_MIN:-15.0}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
STRIP_MOBILE_PATCHES="${STRIP_MOBILE_PATCHES:-1}"

log(){ printf '\033[1;36m[build-node-ios]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[build-node-ios] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

for t in git curl python3 xcrun make; do command -v "$t" >/dev/null || die "missing tool: $t"; done
[ "$(uname -s)" = "Darwin" ] || die "must run on macOS"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK=$SDK"
[ -d "$SDK" ] || die "iphoneos SDK not found"

WORK="$PWD/work"; mkdir -p "$WORK" "$OUT_DIR"
cd "$WORK"

# ---------------------------------------------------------------- 1. 取源
NMB_DIR="$WORK/nodejs-mobile"
if [ ! -d "$NMB_DIR/.git" ]; then
  log "clone nodejs-mobile ($NMB_REF)  [交叉编译管线来源]"
  git clone --depth 1 --branch "$NMB_REF" https://github.com/nodejs-mobile/nodejs-mobile.git "$NMB_DIR"
else
  log "nodejs-mobile already cloned"
fi

# nodejs-mobile 内部用 submodule 指向 node 源; 允许覆盖为指定版本
NODE_DIR="$NMB_DIR/deps/node"
if [ ! -d "$NODE_DIR/.git" ] && [ ! -f "$NODE_DIR/configure.py" ]; then
  log "fetch node v$NODE_VERSION"
  rm -rf "$NODE_DIR"
  git clone --depth 1 --branch "v$NODE_VERSION" https://github.com/nodejs/node.git "$NODE_DIR"
else
  log "node source present: $(git -C "$NODE_DIR" describe --tags 2>/dev/null || echo unknown)"
fi

# ---------------------------------------------------- 2. 剥离 mobile 阉割补丁
if [ "$STRIP_MOBILE_PATCHES" = "1" ]; then
  log "A1: 剥离 nodejs-mobile 的 mobile cripple 补丁"
  PATCH_DIR="$NMB_DIR/patches"
  if [ -d "$PATCH_DIR" ]; then
    mkdir -p "$OUT_DIR/stripped-patches"
    # 风险名单: 命中这些关键词的补丁一律不应用
    RISK_RE='(child_process|child-process|cluster|posix_spawn|spawn|platform.*ios|mobile.*platform|process-exit|wasm|worker_thread)'
    while IFS= read -r p; do
      b="$(basename "$p")"
      if printf '%s' "$b" | grep -Eiq "$RISK_RE"; then
        log "  SKIP  $b"
        mv "$p" "$OUT_DIR/stripped-patches/$b"
      else
        log "  keep  $b"
      fi
    done < <(find "$PATCH_DIR" -type f \( -name '*.patch' -o -name '*.diff' \) 2>/dev/null || true)
  else
    log "  (no patches/ dir at $PATCH_DIR — 需人工核对 upstream 结构)"
  fi
  # nodejs-mobile 也可能把补丁内联在 build script 里, 做一次源码级后处理
  for f in $(find "$NMB_DIR" -maxdepth 2 -name '*.sh' -type f 2>/dev/null); do
    if grep -qE 'child_process|child-process' "$f" 2>/dev/null; then
      log "  WARN  $f 提到 child_process, 需人工复核"
    fi
  done
fi

# ------------------------------------------------------------ 3. 交叉编译
log "configure (arm64 iOS, min=$IOS_MIN)"
cd "$NODE_DIR"

CC_TARGET="arm64-apple-ios$IOS_MIN"
export CC="$(xcrun --sdk iphoneos -f clang)"
export CXX="$(xcrun --sdk iphoneos -f clang++)"
export CPP="$(xcrun --sdk iphoneos -f clang) -E"
export AR="$(xcrun --sdk iphoneos -f ar)"
export LD="$(xcrun --sdk iphoneos -f ld)"
# iOS 上 Node 必须作为共享库链接进 App, 不能编 static main
./configure \
  --dest-cpu=arm64 \
  --dest-os=ios \
  --openssl-no-asm \
  --with-intl=none \
  --without-npm \
  --without-corepack \
  --shared \
  --shared-libname=libnode \
  --cross-compiling \
  --verbose 2>&1 | tail -40 || true

# configure 若不被识别 (upstream node 无 ios dest-os), 走 nodejs-mobile 的脚本
if [ ! -f config.gypi ]; then
  log "fallback: 用 nodejs-mobile 的 configure 包装"
  cd "$NMB_DIR"
  [ -x ./build.sh ] || die "nodejs-mobile/build.sh 缺失, 需人工处理"
  ./build.sh ios
  exit 0
fi

log "make -j$JOBS  (这一步 40-90 分钟)"
make -j"$JOBS" V=0

# ------------------------------------------------------------ 4. 产物处理
LIB="$(find "$NODE_DIR" -name 'libnode*.dylib' -o -name 'libnode*.a' | head -1)"
[ -n "$LIB" ] || die "libnode not produced"
log "libnode = $LIB"
mkdir -p "$OUT_DIR/Frameworks"
cp "$LIB" "$OUT_DIR/Frameworks/"

BIN="$(find "$NODE_DIR" -maxdepth 2 -type f -perm -111 -name 'node' | head -1)"
if [ -n "$BIN" ]; then
  log "node binary = $BIN"
  cp "$BIN" "$OUT_DIR/node-ios-arm64"
  # 越狱机需要签名; adhoc 或 ldid 均可
  if command -v ldid >/dev/null; then ldid -S "$OUT_DIR/node-ios-arm64"; fi
fi

/usr/bin/xcrun --sdk iphoneos lipo -info "$OUT_DIR/Frameworks/"*.dylib 2>/dev/null || true
log "DONE. artifacts in $OUT_DIR"
