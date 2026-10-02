#!/bin/bash
# Offline check: sglang_disagg_mori_io_ep.sh passes --prefill-round-robin-balance only
# to an sglang that defines it (0.5.12 does; 0.5.20 refuses to start on it), and keeps
# passing it when the installed sglang cannot be read. No GPUs, no real sglang.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
# The detection block, exactly as the launcher runs it.
awk '/^_SGL_PRR_FLAG="--prefill-round-robin-balance"/{f=1} f{print} f&&/^fi$/{exit}' \
    "$DIR/sglang_disagg_mori_io_ep.sh" > "$TMP/detect.sh"
printf 'echo "flag=[${_SGL_PRR_FLAG}]"\n' >> "$TMP/detect.sh"

_sglang() { # NAME "server_args.py contents"
    mkdir -p "$TMP/$1/sglang/srt"; : > "$TMP/$1/sglang/__init__.py"
    printf '%s\n' "$2" > "$TMP/$1/sglang/srt/server_args.py"
}
_sglang old 'parser.add_argument("--prefill-round-robin-balance", action="store_true")'
_sglang new 'parser.add_argument("--load-balance-method", type=str)'
mkdir -p "$TMP/none"
_is() { [ "$1" = "$2" ] && { printf "  PASS  %s\n" "$3"; pass=$((pass+1)); } || { printf "  FAIL  %s (got %s, want %s)\n" "$3" "$1" "$2"; fail=$((fail+1)); }; }

_is "$(PYTHONPATH="$TMP/old" bash "$TMP/detect.sh" | tail -1)"  "flag=[--prefill-round-robin-balance]" "sglang that defines the flag (0.5.12): passed"
_is "$(PYTHONPATH="$TMP/new" bash "$TMP/detect.sh" | tail -1)"  "flag=[]"                              "sglang without it (0.5.20): omitted"
_is "$(PYTHONPATH="$TMP/none" PYTHONNOUSERSITE=1 python3 -S -c 'import importlib.util as u; print(u.find_spec("sglang"))' 2>/dev/null)" "None" "(no sglang importable in the 'none' case)"
_is "$(PYTHONPATH="$TMP/none" bash "$TMP/detect.sh" | tail -1)" "flag=[--prefill-round-robin-balance]" "sglang not readable: passed, as before"
_is "$(grep -c -- '--prefill-round-robin-balance \\$' "$DIR/sglang_disagg_mori_io_ep.sh")" "0" "no launch command hardcodes the flag"

echo "======================================================"
echo "  prr_flag_assert: ${pass} passed, ${fail} failed"
echo "======================================================"
[[ "$fail" == "0" ]]
