#!/bin/bash
# Validate the native speech environment; macOS owns language model installation.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
os_version="$(sw_vers -productVersion)"
if (( ${os_version%%.*} < 26 )); then
  echo '둥둥이의 음성 인식에는 macOS 26 이상이 필요합니다.' >&2
  exit 1
fi
swift package resolve
echo 'Apple 음성 인식을 사용합니다. 언어 모델은 앱에서 처음 사용할 때 준비합니다.'
echo 'Whisper 실행 파일이나 별도 모델 설치는 필요하지 않습니다.'
