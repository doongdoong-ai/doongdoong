#!/bin/bash
# Prepare the file transcription engine. No API keys or Python runtime are used.
set -euo pipefail
model_dir="${1:-$HOME/Library/Application Support/Sori/Models}"
mkdir -p "$model_dir"
# Keep the existing lock name so older installers cannot replace a model concurrently.
lock_dir="$model_dir/.turbo-download.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "AI 준비가 이미 진행 중입니다." >&2
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
trap 'exit 129' HUP

prepare_model() {
    local filename="$1" expected_sha="$2" source_url="$3" label="$4" size_label="$5"
    local model_path="$model_dir/$filename"
    if [[ -e "$model_path" && ! -f "$model_path" ]]; then
        echo "$label 위치가 일반 파일이 아닙니다. 경로를 확인해 주세요." >&2
        return 1
    fi
    if [[ -f "$model_path" && -r "$model_path" ]] && [[ "$(shasum -a 256 "$model_path" | cut -d ' ' -f 1)" == "$expected_sha" ]]; then
        echo "$label 확인 완료"
        return 0
    fi

    # A temporary file in the same directory makes the verified replacement atomic.
    partial="$(mktemp "$model_dir/.${filename}.download.XXXXXX")"
    echo "$label 준비 중 ($size_label)."
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 3600 \
        --output "$partial" "$source_url"
    if [[ "$(shasum -a 256 "$partial" | cut -d ' ' -f 1)" != "$expected_sha" ]]; then
        echo "$label 검증에 실패했습니다. 다시 준비해 주세요." >&2
        return 1
    fi
    mv -f "$partial" "$model_path"
    partial=""
    echo "$label 준비 완료"
}

prepare_model "ggml-large-v3-turbo.bin" \
    "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
    "음성 처리 모델" "약 1.62 GB"
prepare_model "ggml-silero-v6.2.0.bin" \
    "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987" \
    "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin" \
    "음성 감지 모델" "885,098 바이트"
echo "AI 준비 완료"
