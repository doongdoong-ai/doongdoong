#!/bin/bash
# The standalone transcription package owns its engine/model installation.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
swift package resolve
core_dir="${DOONGDOONG_TRANSCRIPTION_CORE:-$repo_dir/.build/checkouts/transcription-core}"
[[ -f "$core_dir/scripts/setup-models.sh" ]] || { echo '전사 코어 패키지를 찾지 못했습니다.' >&2; exit 1; }
exec bash "$core_dir/scripts/setup-models.sh" "$@"
