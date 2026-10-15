#!/usr/bin/env bash
# verifies the produced node/libnode on-device capability surface.
set -uo pipefail
BIN="${1:?usage: verify-node-ios.sh <node-ios-arm64>}"
fail=0
chk(){ printf '%-46s ' "$1"; shift; if "$@" >/dev/null 2>&1; then echo OK; else echo "FAIL"; fail=$((fail+1)); fi; }

chk "runs"                 "$BIN" -v
chk "process.platform"     "$BIN" -e 'console.log(process.platform)'
chk "child_process exists" "$BIN" -e 'require("child_process");process.exit(0)'
chk "spawn works"          "$BIN" -e 'const{execSync}=require("child_process");execSync("echo hi")'
chk "fs link"              "$BIN" -e 'require("fs").linkSync' 
chk "worker_threads"       "$BIN" -e 'require("worker_threads")'
chk "no intl (expected)"   "$BIN" -e 'if(process.config.variables.v8_enable_i18n_support)process.exit(1)'
chk "ESM import"           "$BIN" --input-type=module -e 'import fs from "node:fs"'
chk "wasm"                 "$BIN" -e 'new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0]))'
echo
echo "violations: $fail"
[ "$fail" -eq 0 ] && echo "ALL GOOD" || echo "SEE FAILURES ABOVE"
exit "$fail"
