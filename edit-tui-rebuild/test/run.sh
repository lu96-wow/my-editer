#!/usr/bin/env bash
# 跑 edit-tui-rebuild/test 下所有 *.rkt。
# 与 edit-tui-test/run.sh 同样的判定：退出码非 0 或输出含 FAILURE/ERROR。
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
done < <(find "$here" -name '*.rkt' ! -path '*/compiled/*' | sort)
if [ "$fail" -eq 0 ]; then echo "edit-tui-rebuild/test: all clean"; else echo "edit-tui-rebuild/test: FAILURES above"; fi
exit "$fail"
