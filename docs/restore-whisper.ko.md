# 로컬 Whisper 전사 복원 지침

현재 제품 경로에서 Whisper 실행 코드·설정·모델 설치 의존성을 제거했습니다. **이 문서는 나중에 로컬 전사가 다시 필요할 때 이전 구현을 재현하고 최신 앱에 옮기기 위한 지침입니다.** 기존 녹음·전사문·개인 벤치마크를 삭제하거나 새 엔진의 결과로 덮어쓰지 않습니다.

## 복원 기준점

| 저장소 | 고정 기준 | 포함된 동작 |
|---|---|---|
| `doongdoong-ai/doongdoong` | `950f07e2dd1c56f31de21b04058f0b03234849a2` | 로컬 증분 전사, 잠자기·종료 복구, 전체 문맥 교정 v4, 교정 완료 후 공개 |
| `doongdoong-ai/transcription-core` | 태그 `0.1.2`, 커밋 `db8d998094b9ae56ba66bb89c3d286418900b1bb` | 상주 Whisper 서버, Silero VAD, 60초 구간·체크포인트 |
| `doongdoong-ai/codex-core` | 태그 `0.1.1` | 텍스트 모델 연결·로그인·용량 초과 분류 |

전환 전 앱은 이미 전체 교정 v4를 포함합니다. Whisper 복원 때문에 예전의 작은 묶음 교정으로 돌아갈 필요는 없습니다.

## 이전 버전을 별도 폴더에서 재현하기

최신 작업 폴더를 덮어쓰지 말고 기존 앱 저장소에서 실행합니다.

```sh
git fetch origin --tags
git worktree add -b restore/whisper ../doongdoong-whisper-restore \
  950f07e2dd1c56f31de21b04058f0b03234849a2
cd ../doongdoong-whisper-restore
brew install whisper.cpp ffmpeg
swift package resolve
./scripts/setup-engine.sh
swift test
./scripts/build-app.sh
```

당시 확인한 `whisper.cpp`는 **1.9.5**입니다. Homebrew가 다른 버전을 설치하면 서버 옵션·출력 스키마·VAD 동작부터 확인하세요. 모델 기본값은 large-v3-turbo FP16과 Silero VAD 6.2.0입니다. 설치 스크립트가 다음 SHA-256으로 검증합니다.

```text
ggml-large-v3-turbo.bin
1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69

ggml-silero-v6.2.0.bin
2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987
```

모델 기본 경로는 `~/Library/Application Support/Doongdoong/Models`이며, 이전 `Sori/Models`에 같은 파일이 있으면 설치 스크립트가 재사용합니다. 모델이 제거됐으면 위 스크립트로 다시 받습니다. API 키나 서버 계정은 로컬 전사에 필요하지 않으며, 후속 교정·요약에는 Codex 로그인이 필요합니다.

기존 라이브러리를 재처리하지 말고 `--library /별도/검증/폴더`로 샘플부터 검사하세요. 이전 앱을 실행 중인 최신 앱 위에 덮어쓰지 마세요.

## 최신 앱에 이식할 때 필요한 경계

1. 전사 코어의 `WhisperConfiguration`, `WhisperEngine`, `EngineLifetime`, `TranscriptionSession`과 당시 테스트를 기준으로 복원합니다. `SpeechRecognizer`는 0.2에서 `workspace`·처리 단계 콜백을 추가했으므로 기존 구현을 그대로 혼용하지 않습니다.
2. 앱의 `SoriSpeech/LocalTranscription.swift`, `AppSettings`, `TranscriptionPipeline`, `AppStore`에서 엔진 설정·녹음 중 세션·종료/잠자기 해제를 연결합니다. 전체 교정·요약 책임은 그대로 두세요.
3. 이전 엔진은 약 60초씩 처리하고 모델을 메모리에 유지합니다. 공유 엔진의 FIFO 직렬화·취소·모델 교체·소유 프로세스 종료 시 정리를 함께 복원해야 합니다. 녹음마다 새 모델을 로드하는 방식으로 바꾸지 않습니다.
4. 새 엔진의 `transcription/`과 이전 `local-transcription/` 캐시는 서로 다른 결과입니다. 디렉터리 이름만 바꿔 재사용하지 마세요. 완료된 사용자 전사문·편집·원본·`transcript-history/`는 보존합니다.
5. 이전 `timingQuality = whisper`와 현재 `aligned/approximate` 전사문을 모두 읽을 수 있어야 합니다. 로컬 Whisper로 돌아가면 MMS 정렬이 필수인지도 다시 판단하세요. 예전의 Whisper JSON 샘플 파서를 되살릴 필요 없이 현재 네이티브 샘플을 유지할 수 있습니다.
6. 설치 스크립트·설정 UI·README·라이선스 안내를 실제 처리 위치에 맞춰 바꿉니다. 로컬 전사라고 안내하면서 서버에 음성을 보내는 숨은 폴백을 넣지 않습니다.

## 복원 후 최소 검증

- 같은 한국어 강의 구간에서 인식 원문·전문용어·부정·숫자·시험 안내·반복 생성·끝부분 누락을 비교합니다. 클로바노트 출력은 사람이 청취한 정답지와 구분합니다.
- 모델 로딩 포함/제외, 파일 분할, VAD, 양자화, 정렬·교정 포함 여부를 고정해 속도를 측정합니다. 이전 20분 large-v3 Q5 결과를 상주 Turbo의 현재 성능으로 간주하지 않습니다.
- 무음, 아주 짧은 마지막 구간, 5분 이상 증분 녹음, 중간 실패 후 이어하기, 잠자기·종료와 WAV 헤더 복구를 확인합니다.
- 원문·문장 ID·재생 시간이 교정 후 보존되는지, 전체 교정이 끝나기 전 본문·복사·검색·내보내기로 원문이 공개되지 않는지 확인합니다.

개인 강의·비교 원문은 공개 저장소가 아닌 `.local/`의 평가 기록에 보존합니다. 공개 평가 기준은 [평가 프로토콜](evaluation/protocol.ko.md)을 따릅니다.
