import SwiftUI
import AppKit

@MainActor
final class TelegramModel: ObservableObject {
    @Published private(set) var phase = TelegramPhase.configuration
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var hasSavedCredentials = false
    @Published private(set) var qrLink: String?
    @Published private(set) var codeDelivery: TelegramCodeDelivery?
    @Published private(set) var resendRequested = false
    @Published private(set) var chats: [Int64: TelegramChat] = [:]
    @Published private(set) var histories: [Int64: TelegramHistory] = [:]
    @Published private(set) var files: [Int64: TelegramFile] = [:]
    @Published private(set) var users: [Int64: String] = [:]
    @Published private(set) var drafts: [Int64: String] = [:]
    @Published private(set) var photos: [Int64: PhotoAttachment] = [:]
    @Published private(set) var sendStatus: [Int64: String] = [:]
    @Published private(set) var sending = Set<Int64>()
    @Published private(set) var uncertain = Set<Int64>()
    @Published private(set) var hasMoreChats = true
    @Published private(set) var loadingChats = false
    @Published private(set) var connection = "Disconnected"
    @Published private(set) var activity: [Int64: String] = [:]
    @Published var selectedID: Int64?
    @Published var search = ""
    let storage: TelegramStorage
    private let transport: any TelegramTransport
    private var credentials: TelegramCredentials?
    private var databaseKey: Data?
    private var generation = 0
    private var downloads = Set<Int64>()
    private var deleted: [Int64: Set<Int64>] = [:]
    private var typedAt: [Int64: Date] = [:]
    private var submitted: [Int64: (text: String, photo: PhotoAttachment?)] = [:]
    private var pendingMessageIDs: [Int64: Int64] = [:]
    private var earlySendEvents: [Int64: [Int64: TelegramObject]] = [:]
    private var messageRevision: [Int64: [Int64: Int]] = [:]
    private var revision = 0
    private var parametersSubmitted = false
    private var authorizationRevision = 0
    private var activeChat: Int64?
    private var activityExpiry: [Int64: Date] = [:]
    private var outgoingFiles: [Int64: URL] = [:]
    private var expiryTimer: Timer?

    init(transport: (any TelegramTransport)? = nil, storage: TelegramStorage = TelegramStorage()) {
        self.transport = transport ?? TelegramClient()
        self.storage = storage
        self.transport.onUpdate = { [weak self] object in self?.receive(object) }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireMessages() }
        }
    }
    var isReady: Bool { phase == .ready }
    var sortedChats: [TelegramChat] {
        chats.values.filter { chat in
            search.isEmpty || chat.title.localizedCaseInsensitiveContains(search) ||
            chat.preview.localizedCaseInsensitiveContains(search) ||
            (histories[chat.id]?.messages.contains { $0.text.localizedCaseInsensitiveContains(search) } ?? false)
        }.sorted {
            if $0.order != $1.order { return $0.order > $1.order }
            return $0.id < $1.id
        }
    }
    func checkSavedCredentials() {
        do { hasSavedCredentials = try storage.loadCredentials() != nil }
        catch { self.error = TelegramFailure.keychain.localizedDescription }
    }
    func connect(apiID: String? = nil, apiHash: String? = nil) {
        guard phase == .configuration, !busy else { return }
        do {
            let credentials: TelegramCredentials
            if let apiID, let apiHash {
                guard let id = Int32(apiID.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TelegramFailure.invalidCredentials }
                credentials = TelegramCredentials(apiID: id, apiHash: apiHash.trimmingCharacters(in: .whitespacesAndNewlines))
                try storage.saveCredentials(credentials)
            } else {
                guard let saved = try storage.loadCredentials() else { throw TelegramFailure.invalidCredentials }
                credentials = saved
            }
            try storage.prepare()
            databaseKey = try storage.encryptionKey()
            self.credentials = credentials
            hasSavedCredentials = true; error = nil; phase = .connecting
            try transport.start()
        } catch {
            phase = .configuration
            self.error = (error as? TelegramFailure ?? .storage).localizedDescription
        }
    }
    func authenticate(_ input: String) {
        guard !busy else { return }
        let request: TelegramObject
        switch phase {
        case .phone: request = ["@type": "setAuthenticationPhoneNumber", "phone_number": input]
        case .code: request = ["@type": "checkAuthenticationCode", "code": input]
        case .password: request = ["@type": "checkAuthenticationPassword", "password": input]
        case .email: request = ["@type": "setAuthenticationEmailAddress", "email_address": input]
        case .emailCode: request = ["@type": "checkAuthenticationEmailCode", "code": ["@type": "emailAddressAuthenticationCode", "code": input]]
        default: return
        }
        performAuthentication(request)
    }
    var canRequestQRCode: Bool {
        !busy && [.phone, .code, .password, .email, .emailCode].contains(phase)
    }
    func requestQRCode() {
        guard canRequestQRCode else { return }
        performAuthentication(["@type": "requestQrCodeAuthentication", "other_user_ids": [Int64]()])
    }
    func canResendCode(at now: Date = Date()) -> Bool {
        [.code, .emailCode].contains(phase) && !busy && !resendRequested && codeDelivery?.remaining(at: now) == 0
    }
    func resendCode() {
        guard canResendCode() else { return }
        resendRequested = true
        performAuthentication(["@type": "resendAuthenticationCode", "reason": ["@type": "resendCodeReasonUserRequest"]])
    }
    private func performAuthentication(_ request: TelegramObject) {
        busy = true; error = nil
        let token = generation, state = authorizationRevision
        Task {
            do { _ = try await transport.request(request) }
            catch {
                if token == generation && state == authorizationRevision {
                    self.error = (error as? TelegramFailure ?? .rejected).localizedDescription
                    // A timeout may still complete on Telegram. Do not blindly
                    // resend again before a new authorization update arrives.
                    if error as? TelegramFailure != .timeout { resendRequested = false }
                }
            }
            if token == generation { busy = false }
        }
    }
    func receive(_ object: TelegramObject) {
        let type = object.string("@type")
        guard isReady || type == "updateAuthorizationState" || type.hasPrefix("authorizationState") || type == "updateConnectionState" else { return }
        switch object.string("@type") {
        case "updateAuthorizationState": authorization(object.object("authorization_state"))
        case let type where type.hasPrefix("authorizationState"): authorization(object)
        case "updateConnectionState":
            switch object.object("state").string("@type") {
            case "connectionStateReady": connection = "Connected"
            case "connectionStateUpdating": connection = "Syncing"
            case "connectionStateWaitingForNetwork": connection = "Waiting for network"
            default: connection = "Connecting"
            }
        case "updateNewChat":
            let raw = object.object("chat")
            guard raw.object("type").string("@type") != "chatTypeSecret" else { return }
            let chat = TelegramChat(raw); chats[chat.id] = chat
            remember(chat.photo); remember(chat.last?.photo)
            if let photo = chat.photo { download(photo) }
        case "updateUser":
            let user = object.object("user")
            users[user.number("id")] = [user.string("first_name"), user.string("last_name")].filter { !$0.isEmpty }.joined(separator: " ")
        case "updateChatTitle": chats[object.number("chat_id")]?.title = object.string("title")
        case "updateChatPhoto":
            let file = TelegramFile(object.object("photo").object("small"))
            chats[object.number("chat_id")]?.photo = file.id > 0 ? file : nil; remember(file)
            if file.id > 0 { download(file) }
        case "updateChatPosition": chats[object.number("chat_id")]?.order = object.object("position").number("order")
        case "updateChatLastMessage":
            let id = object.number("chat_id"), raw = object.object("last_message")
            let message = raw.isEmpty ? nil : TelegramMessage(raw)
            chats[id]?.last = message; remember(message?.photo)
            chats[id]?.order = object.objects("positions").map { $0.number("order") }.max() ?? 0
        case "updateChatPermissions":
            let id = object.number("chat_id"), permissions = object.object("permissions")
            chats[id]?.canSendText = permissions.flag("can_send_basic_messages")
            chats[id]?.canSendPhotos = permissions.flag("can_send_photos")
        case "updateChatReadInbox": chats[object.number("chat_id")]?.unread = Int(object.number("unread_count"))
        case "updateChatReadOutbox": chats[object.number("chat_id")]?.lastReadOutbox = object.number("last_read_outbox_message_id")
        case "updateNewMessage": mergeMessage(TelegramMessage(object.object("message")))
        case "updateMessageContent":
            let id = object.number("chat_id"), messageID = object.number("message_id")
            let parsed = TelegramMessage.content(object.object("new_content"))
            revision += 1; messageRevision[id, default: [:]][messageID] = revision
            if let index = histories[id]?.messages.firstIndex(where: { $0.id == messageID }) {
                histories[id]?.messages[index].text = parsed.0
                histories[id]?.messages[index].photo = parsed.1
                histories[id]?.messages[index].linkPreview = parsed.2
            }
            if chats[id]?.last?.id == messageID {
                chats[id]?.last?.text = parsed.0
                chats[id]?.last?.photo = parsed.1
                chats[id]?.last?.linkPreview = parsed.2
            }
            remember(parsed.1); if let photo = parsed.1 { download(photo) }
            remember(parsed.2?.photo); if let photo = parsed.2?.photo { download(photo) }
        case "updateDeleteMessages":
            guard object.flag("is_permanent") else { return }
            let id = object.number("chat_id"), ids = Set((object["message_ids"] as? [NSNumber] ?? []).map(\.int64Value))
            deleted[id, default: []].formUnion(ids)
            histories[id]?.messages.removeAll { ids.contains($0.id) }
            if let last = chats[id]?.last, ids.contains(last.id) { chats[id]?.last = histories[id]?.messages.last }
        case "updateMessageSendSucceeded", "updateMessageSendFailed":
            let message = TelegramMessage(object.object("message")), id = message.chatID
            histories[id]?.messages.removeAll { $0.id == object.number("old_message_id") }
            mergeMessage(message)
            if pendingMessageIDs[id] == object.number("old_message_id") { resolveSendEvent(object, chatID: id) }
            else if submitted[id] != nil, pendingMessageIDs[id] == nil {
                // The update can arrive before the awaiting sendMessage task resumes.
                earlySendEvents[id, default: [:]][object.number("old_message_id")] = object
            }
        case "updateFile": remember(TelegramFile(object.object("file")))
        case "updateChatAction":
            let id = object.number("chat_id")
            activity[id] = object.object("action").string("@type") == "chatActionTyping" ? "Typing…" : nil
            activityExpiry[id] = Date().addingTimeInterval(6)
        default: break
        }
    }
    private func authorization(_ object: TelegramObject) {
        authorizationRevision += 1
        error = nil
        if object.string("@type") != "authorizationStateWaitOtherDeviceConfirmation" { qrLink = nil }
        codeDelivery = nil; resendRequested = false
        switch object.string("@type") {
        case "authorizationStateWaitTdlibParameters":
            guard let credentials, let databaseKey, !parametersSubmitted else { return }
            parametersSubmitted = true
            let token = generation
            Task {
                do { _ = try await transport.request(storage.parameters(credentials: credentials, key: databaseKey)) }
                catch { if token == generation { self.error = (error as? TelegramFailure ?? .rejected).localizedDescription } }
            }
        case "authorizationStateWaitPhoneNumber": phase = .phone
        case "authorizationStateWaitOtherDeviceConfirmation":
            phase = .qr
            let link = object.string("link")
            qrLink = TelegramLoginQR.isValid(link) ? link : nil
            if qrLink == nil { error = "Telegram did not provide a valid QR code. Cancel the connection and try again." }
        case "authorizationStateWaitCode":
            phase = .code; codeDelivery = TelegramCodeDelivery(object.object("code_info"))
        case "authorizationStateWaitPassword": phase = .password
        case "authorizationStateWaitEmailAddress": phase = .email
        case "authorizationStateWaitEmailCode":
            phase = .emailCode; codeDelivery = TelegramCodeDelivery(object.object("code_info"), email: true)
        case "authorizationStateReady":
            phase = .ready; busy = false; error = nil; credentials = nil; databaseKey = nil
            loadChats(); updateOnline(NSApp?.isActive == true)
        case "authorizationStateClosing", "authorizationStateLoggingOut": phase = .closing
        case "authorizationStateClosed":
            phase = .configuration; busy = false; connection = "Disconnected"
            clearSession()
        default: phase = .unsupported
        }
    }
    func loadChats() {
        guard isReady, !loadingChats, hasMoreChats else { return }
        loadingChats = true; error = nil
        let token = generation
        Task {
            do { _ = try await transport.request(["@type": "loadChats", "chat_list": ["@type": "chatListMain"], "limit": 100]) }
            catch {
                if token == generation {
                    // loadChats uses a 404 error when all chats have been loaded.
                    if error as? TelegramFailure == .notFound { hasMoreChats = false }
                    else { self.error = (error as? TelegramFailure ?? .rejected).localizedDescription }
                }
            }
            if token == generation { loadingChats = false }
        }
    }
    func loadHistory(_ id: Int64, older: Bool = false) {
        guard isReady, chats[id] != nil else { return }
        var history = histories[id] ?? TelegramHistory()
        guard !history.loading, history.hasMore, older || !history.loaded else { return }
        let before = history.oldestID
        history.loading = true; history.error = nil; histories[id] = history
        let token = generation, requestedRevision = revision
        Task {
            do {
                let result = try await transport.request(["@type": "getChatHistory", "chat_id": id, "from_message_id": before, "offset": 0, "limit": 100, "only_local": false])
                guard token == generation else { return }
                let page = result.objects("messages").map { TelegramMessage($0) }.filter {
                    $0.chatID == id && !(deleted[id]?.contains($0.id) ?? false) && ($0.expiresAt ?? .distantFuture) > Date()
                }.map { message in
                    if (messageRevision[id]?[message.id] ?? 0) > requestedRevision,
                       let updated = histories[id]?.messages.first(where: { $0.id == message.id }) { return updated }
                    return message
                }
                var updated = histories[id] ?? TelegramHistory()
                updated.merge(page)
                let oldest = page.map(\.id).min() ?? before
                updated.hasMore = !page.isEmpty && (before == 0 || oldest < before)
                updated.oldestID = oldest; updated.loading = false; updated.loaded = true
                histories[id] = updated
                for message in page {
                    remember(message.photo); if let photo = message.photo { download(photo) }
                    remember(message.linkPreview?.photo); if let photo = message.linkPreview?.photo { download(photo) }
                }
            } catch {
                guard token == generation else { return }
                histories[id]?.loading = false; histories[id]?.error = (error as? TelegramFailure ?? .rejected).localizedDescription
            }
        }
    }
    private func mergeMessage(_ message: TelegramMessage) {
        guard message.id != 0, !(deleted[message.chatID]?.contains(message.id) ?? false) else { return }
        revision += 1; messageRevision[message.chatID, default: [:]][message.id] = revision
        if histories[message.chatID] != nil { histories[message.chatID]?.merge([message]) }
        if message.date >= (chats[message.chatID]?.last?.date ?? .distantPast) { chats[message.chatID]?.last = message }
        remember(message.photo); if let photo = message.photo { download(photo) }
        remember(message.linkPreview?.photo); if let photo = message.linkPreview?.photo { download(photo) }
    }
    private func remember(_ file: TelegramFile?) {
        guard let file, file.id > 0 else { return }
        files[file.id] = file
        if file.path != nil { downloads.remove(file.id) }
    }
    func download(_ file: TelegramFile) {
        guard isReady, file.id > 0, files[file.id]?.path == nil, !downloads.contains(file.id), file.size <= 20 * 1024 * 1024 else { return }
        downloads.insert(file.id)
        let token = generation
        Task {
            do {
                let result = try await transport.request(["@type": "downloadFile", "file_id": file.id, "priority": 16, "offset": 0, "limit": 0, "synchronous": false])
                if token == generation { remember(TelegramFile(result)) }
            } catch { if token == generation { downloads.remove(file.id) } }
        }
    }
    func draft(_ id: Int64) -> String { drafts[id] ?? "" }
    func setDraft(_ text: String, chatID: Int64) {
        drafts[chatID] = text
        guard isReady, activeChat == chatID, NSApp?.isActive == true else { return }
        if text.isEmpty { fire(["@type": "sendChatAction", "chat_id": chatID, "action": ["@type": "chatActionCancel"]]) }
        else if Date().timeIntervalSince(typedAt[chatID] ?? .distantPast) > 4 {
            typedAt[chatID] = Date()
            fire(["@type": "sendChatAction", "chat_id": chatID, "action": ["@type": "chatActionTyping"]])
        }
    }
    func senderName(_ message: TelegramMessage) -> String {
        message.senderIsChat ? (chats[message.senderID]?.title ?? "Telegram") : (users[message.senderID] ?? "Telegram user")
    }
    func canSend(_ id: Int64) -> Bool {
        guard isReady, !sending.contains(id), !uncertain.contains(id), let chat = chats[id] else { return false }
        if photos[id] != nil { return chat.canSendPhotos }
        return chat.canSendText && !draft(id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft(id).count <= 4096
    }
    func choosePhoto(_ id: Int64) {
        guard isReady, chats[id]?.canSendPhotos == true, !sending.contains(id), !uncertain.contains(id) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg, .png]; panel.allowsMultipleSelection = false
        panel.title = "Choose a Telegram photo"; panel.message = "Choose one JPG or PNG photo, up to 20 MB."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectPhoto(url, chatID: id)
    }
    func selectPhoto(_ url: URL, chatID id: Int64) {
        guard isReady, chats[id]?.canSendPhotos == true, !sending.contains(id), !uncertain.contains(id) else { return }
        do { photos[id] = try PhotoFile.select(url); sendStatus[id] = nil }
        catch { sendStatus[id] = TelegramFailure.photo.localizedDescription }
    }
    func removePhoto(_ id: Int64) { guard !sending.contains(id), !uncertain.contains(id) else { return }; photos[id] = nil }
    func send(_ id: Int64) {
        guard canSend(id) else { return }
        let text = draft(id), photo = photos[id], token = generation
        earlySendEvents[id] = nil
        sending.insert(id); sendStatus[id] = "Sending…"; submitted[id] = (text, photo)
        Task {
            do {
                let content: TelegramObject
                if let photo {
                    let data = try await Task.detached { try PhotoFile.verifiedData(photo) }.value
                    guard token == generation, isReady else { return }
                    let outbox = storage.root.appendingPathComponent("files/outgoing", isDirectory: true)
                    try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let copy = outbox.appendingPathComponent(UUID().uuidString).appendingPathExtension((photo.path as NSString).pathExtension)
                    try data.write(to: copy, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                    outgoingFiles[id] = copy
                    content = ["@type": "inputMessagePhoto", "photo": ["@type": "inputPhoto", "photo": ["@type": "inputFileLocal", "path": copy.path]], "caption": ["@type": "formattedText", "text": "", "entities": []]]
                } else { content = ["@type": "inputMessageText", "text": ["@type": "formattedText", "text": text, "entities": []], "clear_draft": false] }
                guard token == generation, isReady else { return }
                let result = try await transport.request(["@type": "sendMessage", "chat_id": id, "input_message_content": content,
                    "options": ["@type": "messageSendOptions", "paid_message_star_count": 0, "allow_paid_broadcast": false]])
                guard token == generation else { return }
                let message = TelegramMessage(result)
                guard message.chatID == id, message.id != 0 else { throw TelegramFailure.timeout }
                pendingMessageIDs[id] = message.id
                if let event = earlySendEvents.removeValue(forKey: id)?[message.id] {
                    histories[id]?.messages.removeAll { $0.id == message.id }
                    resolveSendEvent(event, chatID: id)
                    return
                }
                mergeMessage(message)
                if message.failed { sending.remove(id); uncertain.insert(id); sendStatus[id] = "Sending failed. Check Telegram before retrying." }
                else if !message.sending { finishSend(id) }
                // Otherwise wait for TDLib's sendSucceeded/sendFailed event. Never
                // resubmit a pending message or create an app-level retry queue.
            } catch {
                guard token == generation else { return }
                sending.remove(id)
                if error as? TelegramFailure == .timeout || error as? TelegramFailure == .closed {
                    uncertain.insert(id); sendStatus[id] = "Send status unknown. Check Telegram before retrying."
                } else {
                    sendStatus[id] = (error as? TelegramFailure ?? .photo).localizedDescription; submitted[id] = nil
                    removeOutgoingCopy(id)
                }
            }
        }
    }
    private func finishSend(_ id: Int64) {
        sending.remove(id); uncertain.remove(id)
        pendingMessageIDs[id] = nil
        earlySendEvents[id] = nil
        removeOutgoingCopy(id)
        if let sent = submitted.removeValue(forKey: id) {
            if let photo = sent.photo { if photos[id] == photo { photos[id] = nil } }
            else if draft(id) == sent.text { drafts[id] = nil }
        }
        sendStatus[id] = "Sent"
    }
    private func resolveSendEvent(_ event: TelegramObject, chatID id: Int64) {
        sending.remove(id); uncertain.remove(id)
        if event.string("@type") == "updateMessageSendSucceeded" { finishSend(id) }
        else {
            removeOutgoingCopy(id)
            sendStatus[id] = "Telegram could not send this message. Check it in Telegram before retrying."
            uncertain.insert(id)
        }
    }
    func acknowledgeUnknown(_ id: Int64) { uncertain.remove(id); submitted[id] = nil; pendingMessageIDs[id] = nil; sendStatus[id] = nil }
    func showChat(_ id: Int64?) {
        guard isReady, activeChat != id else { return }
        if let previous = activeChat { fire(["@type": "closeChat", "chat_id": previous]) }
        activeChat = id
        if let id { fire(["@type": "openChat", "chat_id": id]); loadHistory(id) }
    }
    func hideChat(_ id: Int64) { if activeChat == id { showChat(nil) } }
    func markVisible(_ message: TelegramMessage) {
        guard isReady, activeChat == message.chatID, NSApp?.isActive == true, !message.isOutgoing else { return }
        fire(["@type": "viewMessages", "chat_id": message.chatID, "message_ids": [message.id], "source": ["@type": "messageSourceChatHistory"], "force_read": true])
    }
    func updateOnline(_ online: Bool) {
        guard isReady else { return }
        fire(["@type": "setOption", "name": "online", "value": ["@type": "optionValueBoolean", "value": online]])
    }
    private func fire(_ request: TelegramObject) { Task { _ = try? await transport.request(request) } }
    private func removeOutgoingCopy(_ id: Int64) {
        if let url = outgoingFiles.removeValue(forKey: id) { try? FileManager.default.removeItem(at: url) }
    }
    private func expireMessages() {
        let now = Date()
        for (id, date) in activityExpiry where date <= now { activity[id] = nil; activityExpiry[id] = nil }
        for (id, history) in histories {
            let expired = Set(history.messages.filter { ($0.expiresAt ?? .distantFuture) <= now }.map(\.id))
            if !expired.isEmpty { deleted[id, default: []].formUnion(expired); histories[id]?.messages.removeAll { expired.contains($0.id) } }
        }
        for (id, chat) in chats where (chat.last?.expiresAt ?? .distantFuture) <= now { chats[id]?.last = histories[id]?.messages.last }
    }
    func disconnect() async {
        guard phase != .configuration else { return }
        phase = .closing; generation += 1; busy = false
        qrLink = nil; codeDelivery = nil; resendRequested = false
        await transport.close()
    }
    private func clearSession() {
        generation += 1; credentials = nil; databaseKey = nil; parametersSubmitted = false
        qrLink = nil; codeDelivery = nil; resendRequested = false
        chats = [:]; histories = [:]; users = [:]; files = [:]; drafts = [:]; photos = [:]
        sendStatus = [:]; sending = []; uncertain = []; submitted = [:]; pendingMessageIDs = [:]; downloads = []; deleted = [:]
        activeChat = nil; selectedID = nil; hasMoreChats = true; loadingChats = false
        activity = [:]; activityExpiry = [:]; outgoingFiles = [:]
        earlySendEvents = [:]; messageRevision = [:]; revision = 0
    }
}
