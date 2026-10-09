#!/bin/bash
# Offline check of the stale AITER build-lock cleanup that both launchers run on each
# node before the container starts (run_xPyD_models.slurm, vllm_multinode/run_multinode.slurm).
# Runs the launchers' own lines against a fake JIT cache.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
_has()    { grep -qF -- "$2" <<<"$1" && { printf "  PASS  %s\n" "$3"; pass=$((pass+1)); } || { printf "  FAIL  %s (missing: %s)\n" "$3" "$2"; fail=$((fail+1)); }; }
_snippet() { sed -n '/# AITER builds each JIT module under a lock file/,/^    done;\{0,1\}$/p' "$1"; }

_cache() { # <dir>: a cache with a stale lock, a fresh lock and built modules
    mkdir -p "$1/aiter_jit/build/module_gemm_a8w8_blockscale" "$1/aiter_jit/build/lock_module_moe_dir"
    touch "$1/aiter_jit/build/module_gemm_a8w8_blockscale/module.so" "$1/aiter_jit/module_rmsnorm.so"
    touch -d '3 hours ago' "$1/aiter_jit/build/lock_module_gemm_a8w8_blockscale" "$1/aiter_jit/build/lock_module_moe_dir"
    touch "$1/aiter_jit/build/lock_module_fresh"
}
_left() { (cd "$1" && find . -type f -o -type d -name 'lock_*' | sort | tr '\n' ' '); }

for L in "$DIR/run_xPyD_models.slurm" "$DIR/../vllm_multinode/run_multinode.slurm"; do
    n=$(basename "$L"); S="$(_snippet "$L")"
    echo "=== $n ==="
    _has "$(wc -l <<<"$S" | tr -d ' ')" "15" "$n: carries the cleanup"
    _cache "$TMP/$n/default"
    O="$(env -i PATH="$PATH" _JIT_CACHE_HOST="$TMP/$n/default" bash -c "$S")"
    L1="$(_left "$TMP/$n/default")"
    _has "$O" "removing stale AITER build lock $TMP/$n/default/aiter_jit/build/lock_module_gemm_a8w8_blockscale" "default cache: says which lock it removed"
    _has "$L1" "./aiter_jit/build/module_gemm_a8w8_blockscale/module.so ./aiter_jit/module_rmsnorm.so " "default cache: every lock gone, built modules kept"
    _cache "$TMP/$n/shared"
    env -i PATH="$PATH" _JIT_CACHE_HOST="$TMP/$n/shared" JIT_CACHE_HOST="$TMP/$n/shared" bash -c "$S" >/dev/null
    _has "$(_left "$TMP/$n/shared")" "./aiter_jit/build/lock_module_fresh " "caller-set (maybe shared) cache: a fresh lock is left for its holder"
    _has "$(_left "$TMP/$n/shared")" "./aiter_jit/build/module_gemm_a8w8_blockscale/module.so" "caller-set cache: built modules kept"
    [ -e "$TMP/$n/shared/aiter_jit/build/lock_module_gemm_a8w8_blockscale" ] && r=kept || r=removed
    _has "$r" "removed" "caller-set cache: a 3-hour-old lock is removed"
done
_has "$(diff <(_snippet "$DIR/run_xPyD_models.slurm") <(_snippet "$DIR/../vllm_multinode/run_multinode.slurm") >/dev/null && echo same || echo differs)" "same" "both launchers run the same cleanup"

echo "======================================================"
echo "  jit_lock_assert: ${pass} passed, ${fail} failed"
echo "======================================================"
[[ "$fail" == "0" ]]
