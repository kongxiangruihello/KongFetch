#!/bin/bash
# Run on a Mac: update this branch, then build/test or benchmark the Core package.
# Output goes to Core/.logs/ so it can be read afterwards.
#   bash Core/scripts/mac-test.sh test    build + swift test
#   bash Core/scripts/mac-test.sh bench   synthetic 300k-file tree, new vs 3.2
set -uo pipefail
core="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
logs="$core/.logs"
mkdir -p "$logs"
step="${1:-test}"
cd "$core" || exit 1
echo "running: $step $(date '+%F %T')" > "$logs/status.txt"
git -C "$core/.." pull --ff-only > "$logs/pull.log" 2>&1
{ sw_vers; swift --version; } > "$logs/env.log" 2>&1

case "$step" in
  test)
    swift build --build-tests > "$logs/build.log" 2>&1
    echo "exit $?" >> "$logs/build.log"
    swift test > "$logs/test.log" 2>&1
    echo "exit $?" >> "$logs/test.log"
    ;;
  bench)
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
