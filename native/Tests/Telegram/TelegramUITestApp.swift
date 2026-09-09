import SwiftUI

private final class PreviewSecrets: TelegramSecretStoring {
    var items: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { items[account] }
    func write(_ data: Data, account: String) throws { items[account] = data }
}

@MainActor private final class PreviewTransport: TelegramTransport {
    var onUpdate: ((TelegramObject) -> Void)?
    func start() throws {}
    func request(_ object: TelegramObject) async throws -> TelegramObject {
        if object.string("@type") == "requestQrCodeAuthentication" {
            onUpdate?(["@type": "authorizationStateWaitOtherDeviceConfirmation", "link": "tg://login?token=" + String(repeating: "A", count: 43)])
        }
        if object.string("@type") == "getChatHistory" {
            return ["@type": "messages", "messages": (1...6).map { message(Int64($0)) }]
        }
        return ["@type": "ok"]
    }
    func close() async { onUpdate?(["@type": "updateAuthorizationState", "authorization_state": ["@type": "authorizationStateClosed"]]) }
    func message(_ id: Int64) -> TelegramObject {
        ["id": id, "chat_id": 1, "date": 1700000000 + id * 60, "is_outgoing": id % 2 == 0,
         "sender_id": ["@type": "messageSenderUser", "user_id": 7],
         "content": ["@type": "messageText", "text": ["text": ["Hi! The new inbox is ready.", "한글과 emoji도 그대로 보여요 👋", "Great. Let's try searching the conversation."][Int(id % 3)]]]]
    }
}

@main private struct TelegramUITestApp: App {
    @StateObject private var messages = InboxModel(startTimer: false)
    @StateObject private var telegram: TelegramModel
    private let transport: PreviewTransport
    init() {
        let transport = PreviewTransport()
        self.transport = transport
        let storage = TelegramStorage(secrets: PreviewSecrets(), root: FileManager.default.temporaryDirectory.appendingPathComponent("synapse-ui-fixture"))
        let model = TelegramModel(transport: transport, storage: storage)
        _telegram = StateObject(wrappedValue: model)
    }
    var body: some Scene {
        WindowGroup("Synapse · Synthetic UI Preview") {
            if CommandLine.arguments.contains("--auth-preview") {
                TelegramConnectView(model: telegram).task {
                    transport.onUpdate?(["@type": "authorizationStateWaitCode", "code_info": ["type": ["@type": "authenticationCodeTypeTelegramMessage"], "next_type": ["@type": "authenticationCodeTypeSms"], "timeout": 60]])
                }
            } else {
            SynapseHubView(messages: messages, telegram: telegram).task {
                guard telegram.chats.isEmpty else { return }
                transport.onUpdate?(["@type": "updateAuthorizationState", "authorization_state": ["@type": "authorizationStateReady"]])
                transport.onUpdate?(["@type": "updateNewChat", "chat": ["id": 1, "title": "Jamie 캘리포니아", "type": ["@type": "chatTypePrivate"],
                    "permissions": ["can_send_basic_messages": true, "can_send_photos": true], "last_message": transport.message(6),
                    "positions": [["order": "100"]]]])
                transport.onUpdate?(["@type": "updateUser", "user": ["id": 7, "first_name": "Jamie", "last_name": "Kim"]])
                transport.onUpdate?(["@type": "updateConnectionState", "state": ["@type": "connectionStateReady"]])
            }
            }
        }.defaultSize(width: 1120, height: 800)
    }
}
