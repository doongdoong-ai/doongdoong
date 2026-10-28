# README 제품 이미지 제작 기록

제작일: 2026-10-28. 현재 빌드의 SwiftUI 화면을 앱의 `--snapshot` 기능으로 캡처했다. 개인 라이브러리 대신 매번 새로 복사한 가상 샘플 라이브러리를 `--library`로 지정했다. 화면을 활성화하거나 마이크를 켜지 않았고 AI 요청·전사를 실행하지 않았다. AI 연결 상태는 앱의 미리보기 설정(`--sidebar-ai-preview`, `--providers-preview`)이 만든 가짜 확인 결과다.

| 파일 | 캡처 옵션 | 내용 |
|---|---|---|
| `app-recording.png` | `--workspace-preview` | 녹음 중 화면과 필기, 2560 × 1640 |
| `app-processing.png` | `--polishing-preview` | 정리 진행 카드, 2560 × 1640 |
| `app-summary.png` | (기본) | 핵심 요약 카드, 2560 × 1640 |
| `app-reading.png` | `--transcript-preview` | 전사문과 과목 폴더, 2560 × 1640 |
| `app-ai-vendor.png` | `--providers-preview --providers-claude-preview` | AI 연결 설정, 1640 × 1400 |
| `tour.gif` | 위 캡처 + Codex 선택 상태 설정 화면 | 소개 영상, 1200 × 750, 약 17초 |

모든 캡처에 `--sidebar-ai-preview --providers-claude-preview`를 함께 지정했다.

과목·녹음 제목, 전사문, 강조 카드, 필기는 화면 소개를 위해 직접 작성한 가상 데이터다. 실제 수업이나 AI 분석 결과가 아니다. 파형과 재생 길이는 앱에 포함된 27초 데모 음성을 반복해 만든 75분 음성에서 왔으며, 화면의 가상 강의와 일치하는 녹음으로 주장하지 않는다. 캡처에는 UI가 표시한 내용을 그대로 담았고 이미지 생성으로 화면을 재구성하지 않았다.

`tour.gif`는 `scripts/render-readme-tour.swift`가 캡처에 배경·문구·전환·커서만 덧그린 프레임을 ffmpeg로 인코딩한 것이다. AI 전환 장면은 Codex 선택 화면과 Claude 선택 화면 두 캡처를 교차 전환해 클릭을 표현했다.

```sh
swiftc -O scripts/render-readme-tour.swift -o /tmp/render-tour
/tmp/render-tour SHOTS_DIR FRAMES_DIR
ffmpeg -framerate 15 -i FRAMES_DIR/f%04d.png -vf "scale=1200:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 assets/readme/tour.gif
```

기존 앱 로고의 형태는 변경하지 않았다.
