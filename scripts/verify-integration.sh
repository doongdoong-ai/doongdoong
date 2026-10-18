#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
./scripts/build-app.sh debug
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/sori-acceptance.XXXXXX")"
echo "검증 라이브러리: $test_dir"
"$repo_dir/dist/둥둥이.app/Contents/MacOS/BungBungi" \
  --library "$test_dir/library" --integration-report "$test_dir/report.json"
cat "$test_dir/report.json"
