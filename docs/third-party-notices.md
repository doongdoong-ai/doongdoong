# 외부 구성요소와 라이선스

둥둥이 앱과 전사 코어는 MIT 라이선스입니다. 외부 엔진·모델은 별도 설치하며 저장소나 앱 번들에 가중치를 포함하지 않습니다.

| 구성요소 | 용도 | 라이선스·출처 |
|---|---|---|
| whisper.cpp | 로컬 음성 인식 | MIT · ggml-org/whisper.cpp |
| Whisper large-v3-turbo | 음성 인식 모델 | MIT · openai/whisper, GGML 변환본 ggerganov/whisper.cpp |
| Silero VAD 6.2.0 | 발화 구간 감지 | MIT · snakers4/silero-vad, GGML 변환본 ggml-org/whisper-vad |
| FFmpeg | PCM 형식 변환 | 사용자 설치 빌드의 라이선스 적용 |
| Codex CLI | 교정·제목·핵심 요약 | 별도 설치, 해당 배포 조건·계정 이용 조건 적용 |
| Codex 표시 아이콘 | 설정 화면의 공급자 식별 | OpenAI 공식 VS Code 확장 배포 자산. OpenAI 상표·로고는 앱의 MIT 라이선스 대상이 아닙니다. |

Codex 아이콘은 [OpenAI 공식 확장의 아이콘 자산](https://openai.gallery.vsassets.io/_apis/public/gallery/publisher/openai/extension/chatgpt/latest/assetbyname/Microsoft.VisualStudio.Services.Icons.Default)에서 가져왔습니다. 공급자 식별을 위한 표시이며 OpenAI의 후원이나 제휴를 의미하지 않습니다.

모델 다운로드 원본과 SHA-256은 전사 코어의 scripts/setup-models.sh에 기록되어 있습니다. 자세한 라이선스 원문은 각 구성요소 배포본을 확인하세요.

이전 MMS·Python 정렬 구현은 현재 제품에서 사용하거나 설치하지 않습니다. 과거 비교·복구 코드를 실행하는 개발자를 위한 고지는 [이전 구성요소 안내](legacy-third-party-notices.md)에 보존합니다.
