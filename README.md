<p align="center">
<img src="assets/brand/mark.svg" width="54" height="54" alt="둥둥이 로고">
</p>
<h1 align="center">둥둥이</h1>
<p align="center"><strong>로컬 음성 인식 AI 기반의 대학교 강의 녹음 macOS 앱</strong></p>

클로바노트·다글로의 무료 시간을 다 쓰면 강의 정리용 구독까지 고민하게 됩니다. **이미 Codex나 Claude를 구독하고 있는데도요.**

둥둥이는 **Mac의 음성 인식에 이미 쓰는 AI를 연결하는 오픈소스 앱**입니다. 강의를 녹음하고, 정리된 글을 읽고, 필요한 설명을 다시 들으세요.

![과목별 녹음 목록과 재생 중인 문장을 보여 주는 둥둥이](assets/readme/product-overview.png)

_실제 앱 화면이며, 강의 내용은 소개용 가상 데이터입니다._

## Apple Speech로 빠르게

- **15분 강의를 약 9초에 전사.** M1·8GB에서 금융 강의 15분 분량을 처리한 결과, 기존 Whisper 구현보다 약 **12.3배** 빨랐습니다.
- **Whisper에 가까운 한국어 정확도.** 공개 한국어 낭독 벤치마크의 문자 오류율은 Apple **4.31%**, Whisper Large V3 Turbo **4.25%**였습니다.
- **모델 관리는 macOS가.** 언어 모델을 준비하면 인터넷 없이 음성을 인식합니다. 전사 시간 제한이나 분당 요금도 없습니다.

속도는 교정·요약을 제외한 음성 인식 측정입니다. [측정 조건과 선택 근거](docs/research/apple-speech-selection.ko.md)

## 녹음에서 복습까지

**녹음하며 Mac에서 전사 → Codex로 전체 교정·핵심 요약 → 문장을 눌러 다시 듣기**

- **글과 음성을 함께.** 재생 중인 문장이 가사처럼 강조됩니다. 문장을 누르면 그 부분부터 듣고, 필요한 글은 선택해 복사할 수 있습니다.
- **교수님이 강조한 내용을 카드로.** 핵심 요약에서 원래 설명으로 바로 돌아갈 수 있습니다.
- **과목별로 보관.** 녹음을 폴더로 나누고 검색하세요. 중단된 정리는 이어서 처리할 수 있습니다.

![강조한 설명을 정리한 핵심 요약 카드와 해당 구간 듣기 버튼](assets/readme/app-summary.png)

_소개용 가상 데이터입니다._

현재 교정·요약은 **Codex**에 텍스트를 전달해 처리합니다. 인터넷과 ChatGPT 로그인이 필요하며 계정의 이용 한도가 적용됩니다. 전사문은 교정이 끝난 뒤 표시됩니다.

## 설치

**macOS 26 이상의 Apple Silicon Mac**에서 사용할 수 있습니다. 현재는 소스 빌드 방식입니다. Mac에서 실행 중인 Codex에 아래 내용을 붙여넣으세요.

```text
doongdoong-ai/doongdoong 저장소의 둥둥이를 이 Mac에 설치해 줘.
README, docs/technical-guide.ko.md와 설치 스크립트를 읽고 필요한 도구만 준비해 줘.
./scripts/setup-engine.sh와 ./scripts/build-app.sh로 빌드해 ~/Applications에 설치해 줘.
기존 녹음·설정은 보존하고, 실행 중인 앱을 교체하기 전에는 알려 주고 백업해 줘.
언어 모델 준비와 Codex의 ChatGPT 로그인을 안내해 줘. API 키 결제는 쓰지 마.
테스트·녹음·AI 처리는 실행하지 말고, 설치 후 앱을 백그라운드로 열어 줘.
```

설치 후 **도움말 → 샘플 녹음으로 둘러보기**에서 바로 살펴볼 수 있습니다.

---

SwiftUI·AppKit으로 만든 네이티브 앱입니다. [MIT 라이선스](LICENSE)로 배포합니다.

[빌드·구조·데이터 보관](docs/technical-guide.ko.md) · [평가 기록](docs/validation-apple-transcription.ko.md) · [외부 구성요소](docs/third-party-notices.md)
