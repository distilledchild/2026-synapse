import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ConversationHistory {
    var messages: [ChatMessage] = []
    var oldestRowID: Int64?
    var hasMore = true
    var hasLoaded = false
    var isLoading = false
    var error: String?
}

@MainActor
final class InboxModel: ObservableObject {
    @Published var snapshot = MessageStore.demo
    @Published var selectedID: String? = "team"
    @Published var search = ""
    @Published var isDemo = true
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastUpdated: Date?
    @Published var autoRefresh = true
    @Published private(set) var drafts: [String: String] = [:]
    @Published private(set) var sendResults: [String: SendOutcome] = [:]
    @Published private(set) var sendingChatID: String?
    @Published private(set) var photoDrafts: [String: PhotoAttachment] = [:]
    @Published private(set) var photoErrors: [String: String] = [:]
    @Published private(set) var preparingPhotoChatID: String?
    @Published private(set) var demoImagePaths = Set<String>()
    @Published private(set) var isLiveConnection = false
    @Published private(set) var contactNames: [String: ContactIdentity] = [:]
    @Published private(set) var contactAccess = ContactAccess.notRequested
    @Published private(set) var isLoadingContacts = false
    @Published private(set) var contactsError = false
    @Published private(set) var messageNames: [String: String] = [:]
    @Published private(set) var isLoadingMessageNames = false
    @Published private(set) var messageNamesError: MessageNameError?
    @Published private(set) var histories: [String: ConversationHistory] = [:]
    private var historyGeneration = 0
    private let historyLoader: @Sendable (String, String, Int64?) throws -> Snapshot
    private let sender: any MessageSending
    private let contacts: any ContactProviding
    private let messageNameProvider: any MessageNamesProviding
    private var messageNameGeneration = 0
    private var checkedChatIDs = Set<String>()
    private var messageNamesCheckedAt = Date.distantPast
    private var contactGeneration = 0
    private var lookedUpHandles = Set<String>()
    private let loader: @Sendable (String) throws -> Snapshot
    private var path: String?
    private var generation = 0
    private var timer: Timer?
    private var requestContactsAfterLoad = false

    init(messageNameProvider: any MessageNamesProviding = AppleMessageNames(),
         sender: any MessageSending = AppleMessageSender(), startTimer: Bool = true,
         loader: @escaping @Sendable (String) throws -> Snapshot = { try MessageStore.load(path: $0) },
         contacts: any ContactProviding = AppleContacts(),
         historyLoader: @escaping @Sendable (String, String, Int64?) throws -> Snapshot = {
             try MessageStore.load(path: $0, limit: 1000, conversationID: $1, beforeRowID: $2)
         }) {
        self.sender = sender
        self.contacts = contacts
        self.messageNameProvider = messageNameProvider
        self.loader = loader
        self.historyLoader = historyLoader
        guard startTimer else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoRefresh, !self.isDemo, !self.isLoading else { return }
                self.refresh()
            }
        }
    }
    var allMessages: [ChatMessage] {
        var byID = Dictionary(histories.values.flatMap(\.messages).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in snapshot.messages { byID[message.id] = message }
        return byID.values.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            if $0.sourceRowID != $1.sourceRowID { return $0.sourceRowID < $1.sourceRowID }
            return $0.id < $1.id
        }
    }
    var conversations: [Conversation] {
        Dictionary(grouping: allMessages, by: \.conversationID).map { key, messages in
            Conversation(id: key, title: NamePresentation.title(for: messages.last!, names: contactNames, messageNames: messageNames), messages: messages)
        }.filter { conversation in conversation.messages.contains { matchesSearch($0, title: conversation.title) } }
        .sorted { ($0.last.date ?? .distantPast) > ($1.last.date ?? .distantPast) }
    }
    var selected: Conversation? { conversations.first { $0.id == selectedID } }
    func ensureHistory(for id: String) {
        guard histories[id]?.hasLoaded != true, histories[id]?.error == nil else { return }
        loadOlderHistory(for: id)
    }
    func loadOlderHistory(for id: String) {
        guard let path, !isDemo, snapshot.messages.contains(where: { $0.conversationID == id }) else { return }
        var state = histories[id] ?? ConversationHistory()
        guard !state.isLoading, state.hasMore else { return }
        let before = state.oldestRowID
        state.isLoading = true; state.error = nil; histories[id] = state
        let token = historyGeneration, loader = historyLoader
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try loader(path, id, before) } }.value
            guard token == historyGeneration else { return }
            var updated = histories[id] ?? ConversationHistory()
            updated.isLoading = false
            switch result {
            case .success(let page):
                let merged = Dictionary((updated.messages + page.messages.filter { $0.conversationID == id }).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                updated.messages = Array(merged.values)
                updated.oldestRowID = page.oldestRowID ?? before
                updated.hasMore = page.hasMore && page.oldestRowID != nil && page.oldestRowID != before
                updated.hasLoaded = true
            case .failure(let error): updated.error = error.localizedDescription
            }
            histories[id] = updated
        }
    }
    var isSending: Bool { sendingChatID != nil }
    var isBusy: Bool { isSending || preparingPhotoChatID != nil }
    func draft(for id: String) -> String { drafts[id] ?? "" }
    func setDraft(_ text: String, for id: String) {
        drafts[id] = text
        if sendResults[id] == .accepted || sendResults[id] == .ready { sendResults[id] = nil }
    }
    func senderName(_ address: String) -> String {
        if let message = snapshot.messages.first(where: { NamePresentation.directAddress(for: $0) == address }),
           let name = messageNames[message.conversationID] { return name }
        return contactNames[address]?.name ?? address
    }
    func matchesSearch(_ message: ChatMessage, title: String) -> Bool {
        search.isEmpty || title.localizedCaseInsensitiveContains(search) ||
            message.text.localizedCaseInsensitiveContains(search) || message.conversationTitle.localizedCaseInsensitiveContains(search) ||
            message.sender.localizedCaseInsensitiveContains(search) || senderName(message.sender).localizedCaseInsensitiveContains(search)
    }

    func refreshContactNames(requestPermission: Bool = false, invalidate: Bool = false) {
        guard isLiveConnection else { return }
        refreshMessageNames(invalidate: invalidate)
        if invalidate { clearContactNames() }
        guard !isLoadingContacts else { return }
        contactAccess = contacts.authorization()
        if contactAccess != .authorized && !(requestPermission && contactAccess == .notRequested) {
            clearContactNames()
            return
        }
        guard !contactsError || requestPermission else { return }
        let handles = NamePresentation.handles(in: snapshot).subtracting(lookedUpHandles)
        guard !handles.isEmpty || requestPermission else { return }
        let token = contactGeneration
        isLoadingContacts = true
        contactsError = false
        Task {
            if contactAccess == .notRequested { _ = await contacts.requestAccess() }
            guard token == contactGeneration, isLiveConnection else { return }
            contactAccess = contacts.authorization()
            guard contactAccess == .authorized else { isLoadingContacts = false; return }
            do {
                let names = try await contacts.lookup(handles)
                guard token == contactGeneration, isLiveConnection else { return }
                contactAccess = contacts.authorization()
                guard contactAccess == .authorized else { clearContactNames(); return }
                contactNames.merge(names) { _, new in new }
                lookedUpHandles.formUnion(handles)
                isLoadingContacts = false
                // A message refresh may have introduced more handles during the lookup.
                refreshContactNames()
            } catch {
                guard token == contactGeneration else { return }
                clearContactNames()
                contactsError = true
                contactAccess = contacts.authorization()
            }
        }
    }
    private func clearContactNames() {
        contactGeneration += 1
        contactNames = [:]; lookedUpHandles = []; isLoadingContacts = false; contactsError = false
    }
    func refreshMessageNames(invalidate: Bool = false) {
        guard isLiveConnection else { return }
        if invalidate {
            // Keep visible names while refreshing; generation prevents stale results.
            messageNameGeneration += 1
            checkedChatIDs = []; isLoadingMessageNames = false; messageNamesError = nil
        }
        guard !isLoadingMessageNames else { return }
        if Date().timeIntervalSince(messageNamesCheckedAt) >= 60 { checkedChatIDs = [] }
        let ids = Set(snapshot.messages.map(\.conversationID).filter(MessageNameRequest.isDirectChat)).subtracting(checkedChatIDs)
        guard !ids.isEmpty else { return }
        let token = messageNameGeneration
        isLoadingMessageNames = true
        messageNamesCheckedAt = Date()
        Task {
            do {
                let names = try await messageNameProvider.lookup(ids)
                guard token == messageNameGeneration, isLiveConnection else { return }
                for id in ids { messageNames[id] = names[id] }
                messageNamesError = nil
            } catch {
                guard token == messageNameGeneration, isLiveConnection else { return }
                messageNamesError = error as? MessageNameError ?? .unavailable
                if messageNamesError == .permissionDenied { messageNames = [:] }
            }
            checkedChatIDs.formUnion(ids)
            messageNamesCheckedAt = Date()
            isLoadingMessageNames = false
            refreshMessageNames()
        }
    }
    private func clearMessageNames() {
        messageNameGeneration += 1
        messageNames = [:]; checkedChatIDs = []; isLoadingMessageNames = false; messageNamesError = nil
        messageNamesCheckedAt = .distantPast
    }
    func openContactsPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(url) }
    }
    func canCompose(in id: String) -> Bool {
        let service = snapshot.messages.last { $0.conversationID == id }?.conversationService
        return isDemo || (isLiveConnection && error == nil && SendRequest.isSupportedChat(id, service: service))
    }
    func canSend(to id: String) -> Bool {
        canCompose(in: id) && !isBusy && sendResults[id] != .unknown &&
            (photoDrafts[id]?.isValid ?? SendRequest.isValidText(draft(for: id))) && snapshot.messages.contains { $0.conversationID == id }
    }
    func canSelectPhoto(in id: String) -> Bool {
        canCompose(in: id) && !isBusy && sendResults[id] != .unknown && snapshot.messages.contains { $0.conversationID == id }
    }
    func choosePhoto(for id: String) {
        guard canSelectPhoto(in: id) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a photo to send"
        panel.message = "Choose one JPG, PNG, HEIC, GIF, or WebP photo, up to 20 MB."
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { selectPhoto(url, for: id) }
    }
    func selectPhoto(_ url: URL, for id: String) {
        guard canSelectPhoto(in: id) else { return }
        preparingPhotoChatID = id
        photoDrafts[id] = nil
        photoErrors[id] = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try PhotoFile.select(url) } }.value
            preparingPhotoChatID = nil
            switch result {
            case .success(let photo):
                photoDrafts[id] = photo
                sendResults[id] = nil
            case .failure(let error): photoErrors[id] = error.localizedDescription
            }
        }
    }
    func removePhoto(for id: String) {
        guard !isBusy else { return }
        photoDrafts[id] = nil
        photoErrors[id] = nil
    }
    func acknowledgeUnknown(for id: String) {
        guard !isSending, sendResults[id] == .unknown else { return }
        sendResults[id] = nil
    }
    func send(to id: String) {
        guard canSend(to: id) else { return }
        let text = draft(for: id)
        let photo = photoDrafts[id]
        if isDemo && photo == nil {
            guard let conversation = conversations.first(where: { $0.id == id }) else { return }
            let message = ChatMessage(id: "demo-\(UUID().uuidString)", conversationID: id,
                conversationTitle: conversation.title, sender: "Me", text: text, date: Date(),
                isFromMe: true, bodyUnavailable: false, hasAttachment: false)
            snapshot = Snapshot(messages: snapshot.messages + [message], sourceRows: snapshot.sourceRows + 1, limit: snapshot.limit)
            drafts[id] = ""
            return
        }
        let service = snapshot.messages.last { $0.conversationID == id }?.conversationService
        let request = SendRequest(id: UUID(), chatID: id, text: photo == nil ? text : "", service: service, photo: photo)
        sendingChatID = id
        sendResults[id] = nil
        Task {
            let outcome: SendOutcome
            let validPhoto = await Task.detached(priority: .userInitiated) {
                photo.map { (try? PhotoFile.verifiedData($0)) != nil } ?? true
            }.value
            if !validPhoto {
                outcome = .attachmentUnavailable
            } else if isDemo, let photo {
                demoImagePaths.insert(photo.path)
                let title = snapshot.messages.first { $0.conversationID == id }?.conversationTitle ?? "Sample conversation"
                let message = ChatMessage(id: "demo-\(UUID().uuidString)", conversationID: id,
                    conversationTitle: title, sender: "Me", text: "Attachment", date: Date(),
                    isFromMe: true, bodyUnavailable: false, hasAttachment: true,
                    attachments: [MessageAttachment(id: -Int64(snapshot.sourceRows + 1), filename: photo.path,
                        mimeType: "image/unknown", name: photo.name)])
                snapshot = Snapshot(messages: snapshot.messages + [message], sourceRows: snapshot.sourceRows + 1, limit: snapshot.limit)
                outcome = .accepted
            } else {
                outcome = await sender.send(request)
            }
            sendResults[id] = outcome
            sendingChatID = nil
            if outcome == .accepted {
                if let photo {
                    if photoDrafts[id]?.id == photo.id { photoDrafts[id] = nil }
                } else if drafts[id] == text { drafts[id] = "" }
                refresh()
            }
        }
    }
    func connect(path: String? = nil) {
        guard !isBusy else { return }
        clearContactNames()
        clearMessageNames()
        historyGeneration += 1; histories = [:]
        generation += 1
        // Only the explicit live-connect route can send; imported DBs remain read-only.
        isLiveConnection = path == nil
        requestContactsAfterLoad = isLiveConnection
        drafts = [:]
        photoDrafts = [:]; photoErrors = [:]; demoImagePaths = []
        sendResults = [:]
        self.path = path ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
        isDemo = false
        snapshot = Snapshot(messages: [], sourceRows: 0, limit: 2000)
        selectedID = nil
        error = nil
        lastUpdated = nil
        refresh()
    }
    func refresh() {
        guard let path else { return }
        generation += 1
        let token = generation
        let loader = self.loader
        isLoading = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Snapshot, Error> in
                Result { try loader(path) }
            }.value
            guard token == generation else { return }
            isLoading = false
            switch result {
            case .success(let value):
                // Refresh only replaces the recent range; older loaded pages stay
                // available. Edits/deletions in that recent range still take effect.
                if let cutoff = value.oldestRowID {
                    for id in histories.keys {
                        histories[id]?.messages.removeAll { $0.sourceRowID >= cutoff }
                    }
                }
                snapshot = value; error = nil; lastUpdated = Date()
                let requestPermission = requestContactsAfterLoad
                requestContactsAfterLoad = false
                refreshContactNames(requestPermission: requestPermission)
                if !conversations.contains(where: { $0.id == selectedID }) { selectedID = conversations.first?.id }
            case .failure(let failure):
                snapshot = Snapshot(messages: [], sourceRows: 0, limit: 2000)
                selectedID = nil
                error = failure.localizedDescription
            }
        }
    }
    func disconnect() {
        guard !isBusy else { return }
        clearContactNames()
        clearMessageNames()
        historyGeneration += 1; histories = [:]
        photoDrafts = [:]; photoErrors = [:]; demoImagePaths = []
        drafts = [:]; sendResults = [:]; isLiveConnection = false
        generation += 1; path = nil; isLoading = false; error = nil; isDemo = true
        snapshot = MessageStore.demo; selectedID = "team"; search = ""; lastUpdated = nil
    }
    func chooseDatabase() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Messages database"
        panel.message = "Choose a readable macOS chat.db file. The source database will not be modified."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { connect(path: url.path) }
    }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }
    func openAutomationPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }
}
