# 로컬 작업 규칙 (이 Mac 한정)

- 실행·검색(Spotlight/Cmd+Space)에 잡히는 둥둥이는 `dist/둥둥이.app` 하나뿐이어야 한다. `~/Applications`에는 설치하지 않는다(README의 설치 안내는 공개 사용자용이며 이 Mac에는 적용하지 않는다).
- 앱을 교체하기 전 백업은 `.app` 확장자 그대로 두지 말고 반드시 `<이름>.app.bak`으로 저장한다. `.app`으로 끝나는 번들은 `.local` 안이라도 LaunchServices가 등록해 Cmd+Space에 중복으로 뜬다.
- 백업을 만든 뒤에는 `lsregister -u <경로>`로 등록을 해제한다.
