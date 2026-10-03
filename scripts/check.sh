#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo_root/build/KongFetch.app/Contents/MacOS/KongFetch"
if [[ ! -x "$app" ]]; then bash "$repo_root/scripts/build.sh"; fi
for check in --release30-check --smoke-test --upgrade-check --next-check --control-check; do
  "$app" "$check"
done
