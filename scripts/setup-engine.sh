#!/bin/bash
# Install only the local forced-alignment runtime. ASR uses Codex file dictation.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
alignment_dir="${1:-$HOME/Library/Application Support/Doongdoong/Alignment}"
mkdir -p "$alignment_dir"
lock_dir="$alignment_dir/.setup.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "따라읽기 준비가 이미 진행 중입니다." >&2
    exit 1
fi
partial=""
cleanup() {
    if [[ -n "$partial" ]]; then rm -f -- "$partial"; fi
    rmdir "$lock_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python_bin="${DOONGDOONG_PYTHON:-$(command -v python3.13 || true)}"
if [[ -z "$python_bin" ]]; then
    echo "Python 3.13이 필요합니다: brew install python@3.13" >&2
    exit 1
fi
"$python_bin" -m venv "$alignment_dir/venv"
"$alignment_dir/venv/bin/python" -m pip install --disable-pip-version-check -r "$repo_dir/scripts/alignment-requirements.txt"
model_dir="$alignment_dir/models/hub/checkpoints"
mkdir -p "$model_dir"
model_path="$model_dir/model.pt"
expected_sha="20ef12963ab4924bef49ac4fc7f58ad5da2ee43b2c11bc8c853c9b90ecdbc680"
if [[ ! -f "$model_path" ]] || [[ "$(shasum -a 256 "$model_path" | cut -d ' ' -f 1)" != "$expected_sha" ]]; then
    partial="$(mktemp "$model_dir/.model-download.XXXXXX")"
    if [[ -n "${DOONGDOONG_ALIGNMENT_MODEL_SOURCE:-}" ]]; then
        cp "$DOONGDOONG_ALIGNMENT_MODEL_SOURCE" "$partial"
    else
        echo "따라읽기 모델을 준비합니다. MMS 모델은 CC BY-NC 4.0 라이선스입니다."
        curl --fail --location --retry 3 --connect-timeout 20 --max-time 3600 \
            --output "$partial" "https://dl.fbaipublicfiles.com/mms/torchaudio/ctc_alignment_mling_uroman/model.pt"
    fi
    if [[ "$(shasum -a 256 "$partial" | cut -d ' ' -f 1)" != "$expected_sha" ]]; then
        echo "시간 정렬 모델 검증에 실패했습니다." >&2
        exit 1
    fi
    mv -f "$partial" "$model_path"
    partial=""
fi
echo "따라읽기 준비 완료"
