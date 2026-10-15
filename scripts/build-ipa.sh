#!/usr/bin/env bash
# ============================================================================
#  build-ipa.sh - 把 Node + DSH 引擎 + Swift 壳 组装成未签名 IPA
#  ---------------------------------------------------------------------------
#  关键约束：
#    1. iOS 上所有可执行文件都必须签名。越狱机可以用 adhoc（codesign -s -）
#       或 ldid -S。我们统一用 codesign --force --sign - --entitlements。
#    2. App bundle 内不能 chmod +x 之后直接跑 —— 必须先签名，否则 amfi 杀。
#    3. Node 二进制放在 DSH.app/Frameworks/node 而不是 Resources，
#       因为主程序要用它做 son 的 lite 形式（不加载 dylib，直接起进程）。
#    4. 不用 Xcode project 也能 Xcode build：用 xcodebuild 的 -project，
#       但为了零 Xcode 配置依赖，这里直接手写 app bundle 结构 +
#       Info.plist + ldid。缺点是 Swift 代码需要先编成二进制。
# ============================================================================
set -euo pipefail

APP_SRC="${APP_DIR:-$(pwd)/iosport/app}"
ENGINE="${ENGINE_DIR:-$(pwd)/iosport/engine}"
NODEDIR="${NODE_DIR:-$(pwd)/out-node}"
OUT_IPA="${OUT_IPA:-$(pwd)/dist/DSH.ipa}"
BUNDLE_ID="${BUNDLE_ID:-com.deepseek.dsh.ios}"
APP_NAME="DSH"

log(){ printf '\033[1;33m[build-ipa]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[build-ipa] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

STAGE="$(mktemp -d)"; APP="$STAGE/Payload/$APP_NAME.app"; mkdir -p "$APP"

# ---------------------------------------------------------------- 1. Node 运行时
log 'staging Node runtime'
mkdir -p "$APP/Frameworks"
# CI 直接传 NODE_BIN；本地留一条兜底查找
if [ -z "${NODE_BIN:-}" ]; then
  NODE_BIN="$(find "$NODEDIR" -maxdepth 4 -type f \( -name 'node' -o -name 'node-ios-arm64' -o -name 'node-v*-iphoneos-arm64' \) 2>/dev/null | head -1)"
fi
[ -n "${NODE_BIN:-}" ] || die "node binary not found (NODE_BIN unset, NODEDIR=$NODEDIR)"
[ -f "$NODE_BIN" ] || die "NODE_BIN=$NODE_BIN does not exist"
log "using node: $NODE_BIN ($(du -h "$NODE_BIN" | cut -f1))"
cp "$NODE_BIN" "$APP/Frameworks/node"
chmod +x "$APP/Frameworks/node"
for d in "$NODEDIR"/Frameworks/*.dylib; do
  [ -e "$d" ] || continue
  cp "$d" "$APP/Frameworks/"
done

# ---------------------------------------------------------------- 2. 引擎
log 'staging engine (this is the big one)'
mkdir -p "$APP/Resources/engine"
# 保留符号链接/权限，排除任何 win32 残留
rsync -a --delete \
  --exclude '**/*.pdb' --exclude '**/*.dll' --exclude '**/*.exe' \
  --exclude '**/sharp-win32*' --exclude '**/sherpa-onnx-win*' \
  --exclude '**/ripgrep-win32*' --exclude '**/libreoffice-kit-win32*' \
  "$ENGINE/" "$APP/Resources/engine/"

# iOS shim 必须重建（引擎文件在 rsync 后是新拷的）
log 'applying iOS shims'
bash "$(dirname "$0")/../shims/apply-ios-shims.sh" "$APP/Resources/engine"

# node-pty shim 覆盖
PTY="$APP/Resources/engine/dsh/node_modules/node-pty"
if [ -d "$PTY" ]; then
  cp "$(dirname "$0")/../shims/node-pty-ios.js" "$PTY/lib/ios.js"
fi

# ---------------------------------------------------------------- 3. Swift 主程序
log 'building Swift shell'
SWIFT_SRC="$APP_SRC/DSH"
xcrun -sdk iphoneos swiftc -O -whole-module-optimization \
  -target "arm64-apple-ios15.0" \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -o "$APP/DSH" \
  $(find "$SWIFT_SRC" -name '*.swift' | sort) \
  -framework UIKit -framework WebKit -framework Foundation
chmod +x "$APP/DSH"

# ---------------------------------------------------------------- 4. Info.plist
log 'writing Info.plist'
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>DeepSeek Harness</string>
  <key>CFBundleDisplayName</key><string>DSH</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>15.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
  <key>UIBackgroundModes</key><array><string>fetch</string><string>processing</string></array>
  <key>UIApplicationSceneManifest</key><dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
  </dict>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string></array>
</dict></plist>
PLIST

# ---------------------------------------------------------------- 5. 签名
log 'codesign (adhoc)'
ENT="$APP_SRC/DSH.entitlements"
NODE_ENT="$(dirname "$0")/../node-build/entitlements.plist"
# Node 运行时必须带 dynamic-codesigning，否则 V8 JIT 起不来
if [ -f "$NODE_ENT" ]; then
  codesign --force --sign - --entitlements "$NODE_ENT" "$APP/Frameworks/node"
  echo "[build-ipa] signed Frameworks/node with JIT entitlements"
else
  codesign --force --sign - "$APP/Frameworks/node"
fi
for d in "$APP/Frameworks"/*.dylib; do
  [ -e "$d" ] || continue
  codesign --force --sign - "$d"
done
if [ -f "$ENT" ]; then
  codesign --force --sign - --entitlements "$ENT" "$APP/DSH"
else
  codesign --force --sign - "$APP/DSH"
fi

# ---------------------------------------------------------------- 6. 打 IPA
log 'packaging IPA'
mkdir -p "$(dirname "$OUT_IPA")"
( cd "$STAGE" && zip -qry "$OUT_IPA" Payload )
ls -lh "$OUT_IPA"
log "DONE -> $OUT_IPA"