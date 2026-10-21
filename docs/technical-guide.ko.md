# 둥둥이 구현·운영 상세

둥둥이는 **전사 → 보정 → 강조 내용 분석**으로 책임을 나눕니다. 전사 엔진은 `doongdoong-ai/transcription-core`, 텍스트 AI 연결은 `doongdoong-ai/codex-core`에 분리했습니다. 강의용 프롬프트·분할·재시도·원문 및 근거 검증은 앱에 남아 공급자 교체와 독립적으로 유지됩니다.

## 전사 코어와 앱의 경계

| 구성 | 입력 → 출력 | 소유 코드 |
|---|---|---|
| 전사 | PCM WAV → 원문·시작/종료 시각 | 독립 패키지 `DoongdoongTranscription` |
| 공급자 공통 계약 | 지침·입력 JSON·스키마 → 응답 JSON | `DoongdoongAI/TextGenerationProvider` |
| Codex 연결 | ChatGPT 로그인·모델 조회·CLI 실행 | `DoongdoongCodex/CodexTextProvider` |
| 보정 | 원문·문장 ID → 검증된 교정문 | `SoriCore/LectureReview.swift`, 앱 파이프라인 |
| 강조 분석 | 전사문 → 제목·근거가 있는 요약 카드 | 앱 `TranscriptionPipeline` |
| 녹음·라이브러리·재생 | 사용자 조작 → 파일·UI | `SoriApp` |

앱의 `SoriSpeech/LocalTranscription.swift`는 코어 출력을 기존 `TranscriptSegment`로 바꾸는 어댑터입니다. 코어는 SoriCore, SwiftUI, Codex, 로그인 정보에 의존하지 않습니다. 원문과 타임스탬프는 코어가 결정하고, 보정은 문장 ID·원문·시간을 바꿀 수 없습니다.

## 메모리에 유지한 모델로 증분 처리

AVAudioRecorder가 16 kHz·mono·PCM16 WAV를 저장합니다. 앱이 2초마다 새 구간을 확인하며, 최대 60초 구간의 끝부분 5초에서 260 ms 이상의 쉼을 우선 경계로 사용합니다. 이미 처리한 음성을 겹쳐 반복 디코딩하지 않습니다.

`WhisperEngine` 하나를 녹음과 파일 가져오기 세션이 공유합니다. 첫 요청에서 whisper-server와 large-v3-turbo FP16 모델을 로딩하고 다음 요청부터 재사용합니다. actor의 reentrancy와 별도로 FIFO gate를 두어 추론과 모델 변경을 직렬화합니다. 앱 종료 시 엔진을 해제합니다.

서버는 127.0.0.1의 임시 포트·무작위 경로에서만 동작합니다. WAV multipart 요청의 verbose_json 응답에서 세그먼트 시각을 얻고 구간 오프셋을 더합니다. 리다이렉트를 거부하고 자식 프로세스에 인증정보를 전달하지 않습니다. localhost HTTP는 IPC이며 외부 음성 업로드가 아닙니다.

Silero VAD를 사용하고 디지털 무음은 디코더에 보내지 않습니다. 작은 발화를 놓치거나 Whisper가 반복·환각을 만들 가능성은 남습니다. native timestamp는 단어 단위 강제 정렬이 아니며 정확성을 보증하지 않습니다. 새 결과의 timingQuality는 whisper이고 이전 aligned/approximate 기록도 읽습니다.

정상 녹음 종료는 진행 중인 추론을 취소하지 않습니다. 해당 구간을 마친 뒤 완료한 결과를 재사용하여 마지막 잔여 구간을 처리합니다. 앱 종료·사용자 취소 시 실행 중 엔진을 종료하되 완료된 체크포인트는 유지합니다.

## 실패·재개·분석

구간 완료 전에는 커서를 전진시키지 않습니다. PCM SHA-256·언어·분할 설정·엔진/모델 파일 식별 정보를 확인한 결과만 재사용합니다. 모델은 경로·크기·수정 시각·inode로 식별하므로 실행 중 덮어쓰지 않아야 합니다. 같은 작업 폴더의 중복 처리는 파일 잠금으로 막습니다.

전사 오류는 녹음을 중단하지 않고 30초 뒤 재시도합니다. 미완성 WAV 헤더는 별도 audio-local-recovered.wav로 복구하며 원본은 덮어쓰지 않습니다. 이전 앱의 live-asr 녹음 복구도 유지합니다.

교정·분석보다 전사 원문을 먼저 저장합니다. Codex 연결이 없어도 전사·따라읽기는 완료합니다. 전체 교정은 원문 맥락과 제한된 문장 ID 묶음을 사용하며 공급자·모델·추론 강도별로 캐시합니다. 기존 Codex 캐시는 동일한 설정일 때 읽고, 다른 공급자나 강도의 캐시를 섞지 않습니다. 강조 분석은 실제 발화의 강조 근거와 원문 인용을 검증합니다.

## 공급자 설정과 실행

앱 실행 및 경로 변경 시 `account/read`와 `model/list`로 ChatGPT 로그인과 텍스트 모델 목록을 조회합니다. 자동 선택은 요청한 추론 강도를 지원하는 Sol을 우선하고 Luna를 다음으로 확인합니다. 직접 선택한 모델은 다른 모델로 자동 전환하지 않습니다. `model/list`는 카탈로그이며 권한·잔여 할당량 확인이 아닙니다. 이 구분은 [공식 app-server 안내](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server)에도 명시되어 있습니다.

설정에서 AI 정리 사용 여부, 모델, 추론 강도, 요청별 제한 시간(기본 5분), 실행 파일 경로를 관리합니다. 추론 강도는 카탈로그가 보고한 값만 선택할 수 있습니다. 작업 시작 시 불변 설정 스냅샷을 만들므로 실행 중 변경은 다음 작업부터 반영됩니다.

`CodexTextProvider`는 각 요청 전에 ChatGPT 로그인 상태를 확인하고 API 키 로그인을 거부합니다. 사용자 설정과 규칙을 제외하고 모델·공급자·추론 강도를 명시합니다. 요청별 비공개 임시 작업 폴더에서 CLI를 실행하고 종료 시 정리합니다. 앱은 응답의 JSON 문법뿐 아니라 문장 ID·수정 범위·숫자·부정 표현·근거 인용을 검증합니다. 관련 설정은 [공식 설정 문서](https://developers.openai.com/codex/config-reference/)를 기준으로 하며 CLI 0.160.0에서 명령 옵션을 확인했습니다.

향후 다른 공급자는 `TextGenerationProvider`를 구현하면 됩니다. 공급자 구현은 전사 엔진이나 SwiftUI를 참조하지 않습니다. 로컬 경량 LLM PoC는 채택하지 않았으며, 실험 결과·프롬프트·실행 식별자는 비공개 `.local`에 보관합니다.

## 실제 완료량을 표시하는 진행 상태

진행 화면은 녹음 마무리, 음성 전사, 전체 맥락 확인, 문장 교정, 요약, 긴 강의의 요약 통합, 저장을 구분합니다. 사용자에게는 전사·교정·제목과 핵심 요약·저장 네 단계로 묶어 보여 줍니다.

전사 코어는 체크포인트 검증 후 기존 처리 시간을 전달하고 새 구간을 저장한 뒤에만 완료량을 늘립니다. 교정은 검증된 문장 묶음의 문장 수를 셉니다. 재시도·실패는 완료 수에 더하지 않습니다. 단일 요약 요청처럼 중간 완료량을 알 수 없는 단계에는 불확정 진행 막대를 사용하며, 추정 전체 퍼센트나 남은 시간을 만들지 않습니다.

전사문이 있으면 위쪽의 작은 진행 패널에서 상태를 확인하며 읽기·재생을 계속할 수 있습니다. 대기 중인 녹음은 앞선 작업 수를 보여 주고, 실패한 단계는 완료 표시 대신 원문 유지·재시도 필요로 표시합니다. 요약만 재시도할 때는 요약·저장만 표시합니다.

Whisper 전사는 모델 설치 이후 계정·인터넷·API 비용이 필요 없습니다. Codex는 텍스트 교정·제목·핵심 요약에만 사용하며 계정 한도가 적용됩니다. 이전 내부 받아쓰기·MMS 구현은 과거 비교·복구용으로 남아 있지만 현재 제품 전사 경로에서는 호출하지 않습니다.

## 준비와 빌드

macOS 14+, Swift 6, Homebrew가 필요합니다. whisper.cpp 1.9.5에서 검증했습니다.

```sh
brew install whisper.cpp ffmpeg
./scripts/setup-engine.sh
swift test
./scripts/build-app.sh
```

설치 스크립트는 SPM 의존성을 받은 뒤 전사 코어의 모델 설치 스크립트에 위임합니다. 기본 위치는 ~/Library/Application Support/Doongdoong/Models이며 기존 Sori/Models의 Turbo 모델도 재사용합니다. SHA-256을 검증하고 MMS·Python은 설치하지 않습니다. 기존 모델은 자동 삭제하지 않습니다.

독립 CLI는 코어의 doongdoong-transcribe, 앱 저장소의 호환 명령은 DoongdoongTranscribe입니다. 인자는 AUDIO OUTPUT_DIRECTORY WHISPER_SERVER MODEL VAD [LANGUAGE]이며 교정이나 로그인은 실행하지 않습니다.

--library는 격리된 라이브러리, --demo --snapshot은 창 없는 렌더링입니다. --integration-report는 창·마이크 없이 전사부터 Codex 분석까지 검사하므로 로그인과 계정 한도가 필요합니다.

## 데이터 보관

기본 위치는 ~/Music/둥둥이이며 기존 붕붕이·Sori 라이브러리도 읽습니다. 처리 중에는 이동·삭제를 제한하고 메타데이터를 원자적으로 저장합니다.

```text
녹음 폴더/
├── audio.wav                    # 원본 PCM
├── recording.json               # 제목·문장·메모·파형·핵심 요약
├── local-transcription/         # 구간별 원문·시각·PCM 해시·재개 기록
├── local-asr-original.json       # 합친 원문과 타임스탬프
├── audio-local-recovered.wav    # 중단된 녹음 복구 시에만 생성
├── final-review.json            # 검증된 교정 결과
├── final-review.json.parts/     # 완료한 교정 묶음
├── processing-times.json        # 단계별 시간
└── transcript-history/          # 재처리 전 기존 기록
```

[이번 검증](validation-local-transcription.ko.md) · [이전 파일 전사 검증](validation-codex-file-transcription.ko.md) · [외부 구성요소](third-party-notices.md)

외부 배포용 서명·공증, 화자 분리, 시스템 오디오 녹음, 단어 단위 정렬은 현재 지원하지 않습니다.

## 녹음과 읽기

- 녹음 일시 정지·재개, 입력 레벨, 완료 후 AI 정리 대기열.
- WAV·M4A·MP3 및 동영상 음성 가져오기, 여러 파일 선택·드래그 앤드 드롭.
- 문장 클릭, 반복 재생, 파형 탐색, 10초 이동, 0.5–2배속, 집중 모드.
- 작업 폴더, 이동·이름 변경·즐겨찾기, 제목·텍스트·메모 검색.
- 북마크, 메모 자동 저장, 문장 편집·원문 보기, 글자 크기 조절.
- TXT·SRT·JSON 내보내기, macOS 휴지통으로 삭제.

`도움말 → 샘플 녹음으로 둘러보기`는 미리 준비한 합성 음성과 텍스트를 사용합니다. 샘플 열기는 새 AI 작업을 실행하지 않습니다. 실제 엔진 검증은 별도 통합 검사로 수행합니다.

## 단축키

| 동작 | 단축키 |
|---|---|
| 녹음 시작 / 마치기 | ⌘R |
| 녹음 일시 정지 / 재개 | ⇧⌘R |
| 파일 가져오기 | ⌘O |
| 전사문 / 보관함 찾기 | ⌘F / ⇧⌘F |
| 재생 / 일시 정지 | Space 또는 ⇧⌘P |
| 10초 뒤로 / 앞으로 | ⌘← / ⌘→ |
| 북마크 | ⌘B |
| 집중 모드 | ⇧⌘L |
| 설정 | ⌘, |
