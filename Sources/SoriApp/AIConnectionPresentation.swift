import Foundation
import DoongdoongAI

/// Product copy and recovery actions belong to the app, not vendor error parsing.
struct AIConnectionPresentation {
    enum Action { case retry, signIn, configure, continueUsing }
    let title: String
    let message: String
    let action: Action
    let actionTitle: String

    init(state: AppSettings.AIConnectionState) {
        switch state {
        case .unchecked:
            self.init("AI를 연결해 주세요", "전사문 교정과 핵심 요약을 사용하려면 AI 연결이 필요합니다.", .retry, "연결 확인")
        case .checking:
            self.init("AI 연결을 확인하고 있어요", "짧은 테스트 요청으로 실제 응답을 확인합니다. 잠시만 기다려 주세요.", .retry, "확인 중…")
        case .signingIn:
            self.init("브라우저에서 로그인해 주세요", "로그인을 마치면 여기서 연결을 확인합니다.", .signIn, "로그인 기다리는 중…")
        case .ready:
            self.init("AI 연결을 확인했어요", "이제 전사문을 다듬고 핵심 내용을 정리할 수 있습니다.", .continueUsing, "계속하기")
        case .blocked(let issue):
            switch issue.kind {
            case .installationRequired:
                self.init("Codex를 준비해 주세요", "Codex를 설치하거나, 이미 설치했다면 설정에서 실행 경로를 확인해 주세요.", .configure, "설정 열기")
            case .loginRequired:
                self.init("ChatGPT 로그인이 필요해요", "브라우저에서 로그인하면 둥둥이로 돌아와 연결을 확인합니다.", .signIn, "ChatGPT로 로그인")
            case .unsupportedAuthentication:
                self.init("ChatGPT 계정으로 연결해 주세요", "현재 로그인 방식은 둥둥이에서 지원하지 않습니다. ChatGPT 계정으로 다시 로그인해 주세요.", .signIn, "ChatGPT로 로그인")
            case .configuration:
                self.init("AI 설정을 확인해 주세요", "선택한 모델이나 추론 강도를 사용할 수 없습니다. 설정을 변경한 뒤 다시 확인해 주세요.", .configure, "설정 열기")
            case .network:
                self.init("AI에 연결하지 못했어요", "인터넷 연결을 확인한 뒤 다시 시도해 주세요.", .retry, "다시 확인")
            case .serviceUnavailable:
                self.init("지금은 AI가 응답하지 않아요", "일시적인 서비스 오류일 수 있습니다. 잠시 후 다시 시도해 주세요.", .retry, "다시 확인")
            case .timedOut:
                self.init("연결 확인이 늦어지고 있어요", "기다리는 시간이 길어 확인을 중단했습니다. 다시 시도하거나 녹음을 먼저 시작하세요.", .retry, "다시 확인")
            case .usageLimited:
                let detail = issue.retryAfter.map { "\($0.formatted(date: .abbreviated, time: .shortened)) 이후 다시 확인해 주세요." }
                    ?? "사용량이 회복된 뒤 다시 확인해 주세요."
                self.init("AI 사용 한도에 도달했어요", detail, .retry, "다시 확인")
            case .invalidResponse:
                self.init("AI 응답을 확인하지 못했어요", "다시 시도해 주세요. 같은 문제가 계속되면 Codex를 업데이트한 뒤 확인해 주세요.", .retry, "다시 확인")
            case .unknown:
                self.init("AI 연결을 확인하지 못했어요", "다시 확인해 주세요. 문제가 계속되면 설정에서 AI 연결 상태와 진단 정보를 확인해 주세요.", .retry, "다시 확인")
            }
        }
    }

    private init(_ title: String, _ message: String, _ action: Action, _ actionTitle: String) {
        self.title = title; self.message = message; self.action = action; self.actionTitle = actionTitle
    }
}
