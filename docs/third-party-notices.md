# 외부 구성요소와 라이선스

둥둥이 앱과 전사 코어는 MIT 라이선스입니다. Apple 언어 모델은 macOS가 관리하며 저장소나 앱 번들에 가중치를 포함하지 않습니다.

| 구성요소 | 용도 | 라이선스·출처 |
|---|---|---|
| Apple Speech·언어 모델 | 기기 내 음성 인식 | Apple SDK·macOS 이용 조건 적용. MIT 대상이 아님 |
| FFmpeg | PCM 형식 변환 | 사용자 설치 빌드의 라이선스 적용 |
| Codex CLI | 교정·제목·핵심 요약 | 별도 설치, 해당 배포 조건·계정 이용 조건 적용 |
| Codex 표시 아이콘 | 설정 화면의 공급자 식별 | OpenAI 공식 VS Code 확장 배포 자산. OpenAI 상표·로고는 앱의 MIT 라이선스 대상이 아닙니다. |

Codex 아이콘은 [OpenAI 공식 확장의 아이콘 자산](https://openai.gallery.vsassets.io/_apis/public/gallery/publisher/openai/extension/chatgpt/latest/assetbyname/Microsoft.VisualStudio.Services.Icons.Default)에서 가져왔습니다. 공급자 식별을 위한 표시이며 OpenAI의 후원이나 제휴를 의미하지 않습니다.

이전 Whisper·Silero 구성의 라이선스와 다운로드 기록은 전사 코어 0.1.2 태그에 보존합니다. 현재 앱은 해당 엔진과 모델을 설치하거나 호출하지 않습니다.

이전 MMS·Python 정렬 구현은 현재 제품에서 사용하거나 설치하지 않습니다. 과거 비교·복구 코드를 실행하는 개발자를 위한 고지는 [이전 구성요소 안내](legacy-third-party-notices.md)에 보존합니다.
