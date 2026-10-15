#!/usr/bin/env bash
# ============================================================================
#  pack-engine.sh - 把已抽取+已打 shim 的引擎打包成 engine.tar.zst
#  ---------------------------------------------------------------------------
#  为什么需要：IPA 组装需要 111MB 的引擎，它不适合直接进 git 仓库。
#  做法：本地抽好 → 打 shim → 压成 tar.zst → 传到 GitHub Release（tag: engine）
#        → build.yml 里下载解压。
#
#  用法：
#    bash iosport/scripts/pack-engine.sh
#  产出：dist/engine.tar.zst + dist/engine.sha256
# ============================================================================
set -euo pipefail

ENGINE="${ENGINE_DIR:-$(pwd)/_iosport/engine}"
OUT="${OUT_DIR:-$(pwd)/dist}"
mkdir -p "$OUT"

[ -d "$ENGINE/dsh/node_modules/@deepseek-ai/dsh" ] || {
  echo "FATAL: engine not found at $ENGINE" >&2; exit 1; }

echo "[pack] engine size before prune:"
du -sh "$ENGINE"

# 二次清理：确保没有任何 win32 原生残留
find "$ENGINE" -type f \(
  -name '*.node' -o -name '*.dll' -o -name '*.exe' -o -name '*.lib' \
  -o -name '*.pdb' -o -name '*.so' -o -name '*.dylib' \
  \) -path '*win32*' -print -delete 2>/dev/null || true
rm -rf "$ENGINE"/**/sharp-win32* \
       "$ENGINE"/**/sherpa-onnx-win* \
       "$ENGINE"/**/ripgrep-win32* \
       "$ENGINE"/**/libreoffice-kit-win32* 2>/dev/null || true

echo "[pack] engine size after prune:"
du -sh "$ENGINE"

# tar.zst（比 gzip 小 30%，iOS 端用 tar + zstd 解；或 CI 里解好后直接进 IPA）
TMPTAR="$(mktemp -d)/engine.tar"
tar -C "$(dirname "$ENGINE")" -cf "$TMPTAR" "$(basename "$ENGINE")"
if command -v zstd >/dev/null 2>&1; then
  zstd -19 -T0 -o "$OUT/engine.tar.zst" "$TMPTAR"
else
  echo '[pack] zstd 不可用，退回 gzip'
  gzip -9 -c "$TMPTAR" > "$OUT/engine.tar.gz"
  OUT_TARBALL="$OUT/engine.tar.gz"
fi
OUT_TARBALL="${OUT_TARBALL:-$OUT/engine.tar.zst}"
ls -lh "$OUT_TARBALL"
shasum -a 256 "$OUT_TARBALL" | tee "$OUT/engine.sha256"
rm -rf "$(dirname "$TMPTAR")"
echo "[pack] DONE -> $OUT_TARBALL"