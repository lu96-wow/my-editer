#!/usr/bin/env bash
# 跑 core-test 下所有 *.rkt。
# 测试是脚本（rackunit 失败只打印、不中止），故以输出是否含 FAILURE 判定；任一失败退出码非 0。
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
while IFS= read -r f; do
  out="$(racket "$f" 2>&1)"
  if printf '%s' "$out" | grep -q 'FAILURE'; then
    printf 'FAIL: %s\n%s\n' "$f" "$out"
    fail=1
  fi
done < <(find "$here" -name '*.rkt' ! -name 'run.rkt' ! -path '*/compiled/*' | sort)
if [ "$fail" -eq 0 ]; then echo "core-test: all clean"; else echo "core-test: FAILURES above"; fi
exit "$fail"
