#!/usr/bin/env bash
# 跑 edit-tui/test 下所有 *.rkt。
# 先 raco make（编译依赖），再运行；编译失败就不跑测试。
# 判定：退出码非 0 或输出含 FAILURE/ERROR。
set -u
here="$(cd "$(dirname "$0")" && pwd)"

files() {
  find "$here" -name '*.rkt' ! -path '*/compiled/*' | sort
}

# 1) 先编译：任何文件失败都先报出来，避免把编译错误混进测试输出。
compile_fail=0
while IFS= read -r f; do
  out="$(raco make "$f" 2>&1)"
  code=$?
  if [ "$code" -ne 0 ]; then
    printf 'COMPILE FAIL: %s (exit %s)\n%s\n' "$f" "$code" "$out"
    compile_fail=1
  fi
done < <(files)

if [ "$compile_fail" -ne 0 ]; then
  echo "edit-tui/test: COMPILE FAILURES above"
  exit 1
fi

# 2) 再运行测试。
fail=0
while IFS= read -r f; do
  out="$(racket "$f" 2>&1)"
  code=$?
  if [ "$code" -ne 0 ] || printf '%s' "$out" | grep -Eqi 'failure|error'; then
    printf 'FAIL: %s (exit %s)\n%s\n' "$f" "$code" "$out"
    fail=1
  fi
done < <(files)

if [ "$fail" -eq 0 ]; then echo "edit-tui/test: all clean"; else echo "edit-tui/test: FAILURES above"; fi
exit "$fail"
