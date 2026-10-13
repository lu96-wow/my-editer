#!/usr/bin/env bash
# 跑 core-test 下所有 *.rkt。
# 测试是脚本（rackunit 失败只打印、不中止），故以「退出码非 0」或「输出含 FAILURE/ERROR」判定。
# 只看 FAILURE 会漏掉编译错误和 check-* 抛异常（rackunit 记作 ERROR）。
set -u
here="$(cd "$(dirname "$0")" && pwd)"
fail=0
while IFS= read -r f; do
  out="$(racket "$f" 2>&1)"
  code=$?
  if [ "$code" -ne 0 ] || printf '%s' "$out" | grep -Eqi 'failure|error'; then
    printf 'FAIL: %s (exit %s)\n%s\n' "$f" "$code" "$out"
    fail=1
  fi
done < <(find "$here" -name '*.rkt' ! -name 'run.rkt' ! -path '*/compiled/*' | sort)
if [ "$fail" -eq 0 ]; then echo "core-test: all clean"; else echo "core-test: FAILURES above"; fi
exit "$fail"
