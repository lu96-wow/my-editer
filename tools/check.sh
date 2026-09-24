#!/usr/bin/env bash
# tools/check.sh —— 预编译（并行）→ 测试 → 清理编译缓存
#
#   bash tools/check.sh              # make -j → test → clean（默认）
#   bash tools/check.sh --keep       # make -j → test（保留 .zo，便于连续跑）
#   bash tools/check.sh --no-make    # 跳过 make，直接 test（.zo 需已在，最快）
#   JOBS=8 bash tools/check.sh       # 指定并行度（默认 nproc）
#
# 为什么这样：`raco test` 没有并行选项；冷跑要顺序编译（本项目 ~2m44s）。
#   先 `raco make -j` 并行编译出 .zo（冷 ~12s），再 `raco test` 直接复用（~19s）。
#   （注意 `raco make -j` 官方支持并行，但本项目依赖链接近线性，并行收益有限。）
#
# 失败即停：测试失败时不会清理，.zo 留下，重跑更快。
set -euo pipefail

cd "$(dirname "$0")/.."

KEEP=0
NO_MAKE=0
for a in "$@"; do
  case "$a" in
    --keep)    KEEP=1 ;;
    --no-make) NO_MAKE=1; KEEP=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

JOBS="${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
RKT=$(find core io tools default-editor ui -name '*.rkt' | sort)

if [ "$NO_MAKE" -eq 0 ]; then
  echo "== 1/3 raco make -j $JOBS（并行预编译）=="
  # shellcheck disable=SC2086
  raco make -j "$JOBS" $RKT
else
  echo "== 1/3 跳过 make（--no-make）=="
fi

echo
echo "== 2/3 raco test core io tools default-editor ui =="
raco test core io tools default-editor ui

if [ "$KEEP" -eq 0 ]; then
  echo
  echo "== 3/3 清理编译缓存（compiled/）=="
  find core io tools default-editor ui -type d -name compiled -prune -exec rm -rf -- {} +
  echo "cleaned."
else
  echo
  echo "== 3/3 保留 compiled/（--keep / --no-make）=="
fi
