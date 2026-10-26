#!/bin/bash
# Run on a Mac: build/test or benchmark the Core package (code is synced separately).
# Output goes to Core/.logs/ so it can be read afterwards.
#   bash Core/scripts/mac-test.sh test    build + swift test
#   bash Core/scripts/mac-test.sh bench   synthetic 300k-file tree, new vs 3.2
#   bash Core/scripts/mac-test.sh all     test, then bench if the build succeeded
set -uo pipefail
core="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
logs="$core/.logs"
mkdir -p "$logs"
step="${1:-test}"
say() { echo "[KongFetchCore] $*"; }
cd "$core" || exit 1
if [ "$step" = "all" ]; then
  bash "$core/scripts/mac-test.sh" test
  if grep -q '^exit 0$' "$logs/build.log"; then bash "$core/scripts/mac-test.sh" bench; fi
  say "全部完成，结果在 $logs ，可以回到 Claude 了。"
  exit 0
fi
echo "running: $step $(date '+%F %T')" > "$logs/status.txt"
{ sw_vers; swift --version; } > "$logs/env.log" 2>&1

case "$step" in
  test)
    say "编译中（首次约需 1–3 分钟）…"
    swift build --build-tests > "$logs/build.log" 2>&1
    echo "exit $?" >> "$logs/build.log"
    if grep -q '^exit 0$' "$logs/build.log"; then
      say "运行测试…"
      swift test > "$logs/test.log" 2>&1
      echo "exit $?" >> "$logs/test.log"
      say "测试结束：$(tail -1 "$logs/test.log")"
    else
      say "编译未通过，错误已记录。"
    fi
    ;;
  bench)
    say "运行性能对比（生成 30 万个测试文件，约需数分钟）…"
    tree="${TMPDIR:-/tmp}kfbench-tree"
    files="${2:-300000}"
    swift build -c release --product kfbench > "$logs/bench-build.log" 2>&1
    echo "exit $?" >> "$logs/bench-build.log"
    bin="$(swift build -c release --show-bin-path)/kfbench"
    if [ ! -f "$tree/.done-$files" ]; then
      rm -rf "$tree"
      "$bin" synth "$tree" "$files" > "$logs/bench-synth.log" 2>&1 && touch "$tree/.done-$files"
    fi
    "$bin" new "$tree" > "$logs/bench-new.log" 2>&1
    echo "exit $?" >> "$logs/bench-new.log"
    "$bin" legacy "$tree" > "$logs/bench-legacy.log" 2>&1
    echo "exit $?" >> "$logs/bench-legacy.log"
    ;;
  *)
    echo "unknown step: $step" >> "$logs/status.txt"
    exit 2
    ;;
esac
echo "done: $step $(date '+%F %T')" >> "$logs/status.txt"
