import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Contacts

struct InboxView: View {
    @ObservedObject var model: InboxModel
    var detailOnly = false
    var attachmentRoot: URL = AttachmentImageLoader.messagesRoot
    @State private var showHelp = false
    @State private var composerHeight: CGFloat = 32
    @State private var historyScrollTarget: String?
    @State private var matchIndex = 0
    @State private var initialHistoryPending = false
    @State private var followingLatest = true
    @Environment(\.scenePhase) private var scenePhase
    private let accent = Color(red: 0.43, green: 0.34, blue: 0.88)
    var body: some View {
        Group {
            if detailOnly { detail }
            else { NavigationSplitView { sidebar } detail: { detail } }
        }
        .frame(minWidth: detailOnly ? 540 : 900, minHeight: 620)
        .toolbar {
            ToolbarItemGroup {
                Button { model.chooseDatabase() } label: { Label("Open database", systemImage: "folder") }.help("Choose another chat.db file").disabled(model.isBusy)
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.isDemo || model.isLoading).keyboardShortcut("r", modifiers: .command)
                Button { showHelp = true } label: { Label("Help", systemImage: "info.circle") }
            }
        }
        .sheet(isPresented: $showHelp) { helpView }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refreshContactNames(invalidate: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            model.refreshContactNames(invalidate: true)
        }
        .onChange(of: model.search) { _ in
            if !model.conversations.contains(where: { $0.id == model.selectedID }) { model.selectedID = model.conversations.first?.id }
        }
    }
    private var sidebar: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 24)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Synapse").font(.system(size: 23, weight: .bold, design: .rounded))
                        Text("All your conversations, together").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
                HStack {
                    Label("Apple Messages", systemImage: "message.fill").font(.headline)
                    Spacer()
                    Text(model.isDemo ? "Sample" : model.error == nil ? "Connected" : "Connection needed")
                        .font(.caption2.bold()).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(accent.opacity(0.12), in: Capsule()).foregroundStyle(accent)
                }.padding(.horizontal, 20).padding(.bottom, 12)
                TextField("Search conversations and messages", text: $model.search)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                List(selection: $model.selectedID) {
                    ForEach(model.conversations) { conversation in
                        HStack(alignment: .top, spacing: 11) {
                            ZStack {
                                Circle().fill(accent.opacity(0.12)).frame(width: 36, height: 36)
                                if let initials = NamePresentation.initials(for: conversation.title) {
                                    Text(initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                                } else {
                                    Image(systemName: "person.fill").font(.system(size: 14)).foregroundStyle(accent)
                                }
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(conversation.last.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 7).tag(conversation.id)

                    }
                }.listStyle(.sidebar)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if model.isLiveConnection {
                        if model.isLoadingMessageNames {
                            Label("Loading names from Messages…", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                        } else if let error = model.messageNamesError {
                            if error == .permissionDenied {
                                Button("Messages access settings") { model.openAutomationPrivacy() }.font(.caption)
                            } else {
                                Button("Reload Messages names") { model.refreshMessageNames(invalidate: true) }.font(.caption)
                            }
                        }
                        if model.isLoadingContacts {
                            Label("Loading contact names…", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary)
                        } else if model.contactAccess == .notRequested {
                            Button { model.refreshContactNames(requestPermission: true) } label: {
                                Label("Show contact names", systemImage: "person.crop.circle")
                            }.font(.caption)
                        } else if model.contactAccess == .denied || model.contactAccess == .restricted {
                            Button("Contacts access settings") { model.openContactsPrivacy() }.font(.caption)
                        } else if model.contactsError {
                            Button("Reload contact names") { model.refreshContactNames(invalidate: true) }.font(.caption)
                        }
                    }
                    if model.isDemo {
                        Button { model.connect() } label: {
                            Label("Connect Messages", systemImage: "link").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                    } else {
                        HStack {
                            Toggle("Auto-refresh", isOn: $model.autoRefresh).toggleStyle(.switch).controlSize(.mini)
                            Spacer()
                            Button("Disconnect") { model.disconnect() }.font(.caption).disabled(model.isBusy)
                        }
                    }
                    HStack {
                        Label("On this Mac only", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { showHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain)
                    }
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
    }
    private var detail: some View {
            VStack(spacing: 0) {
                if model.isDemo {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("These are sample conversations. Connect Messages to read your conversations.")
                        Spacer()
                    }.font(.callout).padding(14).background(accent.opacity(0.08))
                }
                if let error = model.error {
                    permissionView(error)
                } else if model.isLoading && model.snapshot.messages.isEmpty {
                    Spacer(); ProgressView("Loading messages…"); Spacer()
                } else if let conversation = model.selected {
                    conversationView(conversation)
                } else {
                    Spacer()
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 48)).foregroundStyle(accent.opacity(0.6))
                    Text(model.search.isEmpty ? "No conversations to show" : "No results").font(.title2.bold()).padding(.top, 12)
                    Text(model.search.isEmpty ? "Check Messages sync or choose another database." : "Search covers loaded messages. Load older history to include it in search.")
                        .foregroundStyle(.secondary).padding().multilineTextAlignment(.center)
                    Spacer()
                }
                Divider()
                InboxStatusBar(isDemo: model.isDemo, isLiveConnection: model.isLiveConnection,
                    hasError: model.error != nil,
                    messageCount: model.isDemo ? model.snapshot.sourceRows : model.allMessages.count,
                    unavailableCount: model.snapshot.unavailableCount,
                    isRefreshing: model.isLoading, lastUpdated: model.lastUpdated)
            }.frame(minWidth: 540)
    }
    private func permissionView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(accent)
            Text("Allow access to Messages").font(.title.bold())
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Text("1. Move Synapse to Applications and open it.")
                Text("2. Enable Synapse in System Settings → Privacy & Security → Full Disk Access.")
                Text("3. Quit and reopen Synapse, then connect Messages.")
            }.font(.callout)
            HStack {
                Button("Open System Settings") { model.openPrivacy() }.buttonStyle(.borderedProminent).tint(accent)
                Button("Try again") { model.refresh() }
                Button("Back to sample") { model.disconnect() }
            }
            Text("The source database stays unchanged. Granting access does not send messages.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }.padding(44).frame(maxWidth: 720, maxHeight: .infinity)
    }
    private func conversationView(_ conversation: Conversation) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title).font(.title2.bold()).textSelection(.enabled)
                    Text("\(model.isDemo ? "Sample" : conversation.serviceLabel) · \(conversation.messages.count) messages loaded").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { openMessages() } label: { Image(systemName: "message.fill").foregroundStyle(.green).font(.title2) }
                    .buttonStyle(.plain).help("Open Apple Messages")
            }.padding(24)
            Divider()
            ScrollViewReader { proxy in
                HStack(spacing: 12) {
                    if !model.isDemo {
                        let history = model.histories[conversation.id]
                        if history?.isLoading == true {
                            ProgressView().controlSize(.small)
                            Text("Loading history…")
                        } else if history?.hasMore != false {
                            Button(history?.error == nil ? "Load older messages" : "Retry history") {
                                followingLatest = false
                                historyScrollTarget = conversation.messages.first?.id
                                model.loadOlderHistory(for: conversation.id)
                            }
                        } else { Text("All local history loaded").foregroundStyle(.secondary) }
                        if let error = history?.error { Text(error).foregroundStyle(.orange).lineLimit(2) }
                    }
                    Spacer()
                    if !model.search.isEmpty {
                        let matches = conversation.messages.filter { $0.text.localizedCaseInsensitiveContains(model.search) }
                        Text("\(matches.count) matches · Full conversation").foregroundStyle(.secondary)
                        if !matches.isEmpty {
                            Button("Next match") {
                                followingLatest = false
                                proxy.scrollTo(matches[matchIndex % matches.count].id, anchor: .center)
                                matchIndex += 1
                            }
                        }
                    }
                    Button("Latest") {
                        followingLatest = true
                        if let last = conversation.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(conversation.messages) { message in
                            HStack(alignment: .bottom) {
                                if message.isFromMe { Spacer(minLength: 70) }
                                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 5) {
                                    if !message.isFromMe && conversation.id.contains(";+;") {
                                        Text(model.senderName(message.sender)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    VStack(alignment: .leading, spacing: 7) {
                                        if message.text != "Attachment" || message.attachments.isEmpty {
                                            Text(message.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        }
                                        ForEach(message.visibleAttachments) { attachment in
                                            if attachment.isImage {
                                                AttachmentPreview(attachment: attachment,
                                                    allowsLocalFiles: model.isLiveConnection || model.demoImagePaths.contains(attachment.filename ?? ""),
                                                    imageRoot: model.isDemo && model.demoImagePaths.contains(attachment.filename ?? "") ? URL(fileURLWithPath: attachment.filename!).deletingLastPathComponent() : attachmentRoot)
                                            } else {
                                                Label(attachment.name, systemImage: "paperclip").font(.caption).lineLimit(2)
                                            }
                                        }
                                        if let title = message.linkPreview?.title {
                                            Text(title).font(.callout.weight(.medium)).lineLimit(3)
                                        }
                                        if message.hasAttachment && message.attachments.isEmpty {
                                            Label("View this attachment in Messages", systemImage: "paperclip").font(.caption2)
                                        }
                                        if message.bodyUnavailable { Label("Unsupported message format", systemImage: "exclamationmark.circle").font(.caption2) }
                                    }.padding(.horizontal, 16).padding(.vertical, 12)
                                        .foregroundStyle(message.isFromMe ? Color.white : Color.primary)
                                        .background(message.isFromMe ? accent : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
                                        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(
                                            !model.search.isEmpty && message.text.localizedCaseInsensitiveContains(model.search) ? Color.orange : .clear, lineWidth: 2))
                                    if let date = message.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: 540, alignment: message.isFromMe ? .trailing : .leading)
                                if !message.isFromMe { Spacer(minLength: 70) }
                            }.id(message.id)
                        }
                    }.padding(24)
                }
                .task(id: conversation.id) {
                    historyScrollTarget = nil; matchIndex = 0
                    followingLatest = model.search.isEmpty
                    initialHistoryPending = model.histories[conversation.id]?.hasLoaded != true
                    model.ensureHistory(for: conversation.id)
                    if let target = conversation.messages.first(where: { !model.search.isEmpty && $0.text.localizedCaseInsensitiveContains(model.search) }) {
                        matchIndex = 1
                        proxy.scrollTo(target.id, anchor: .center)
                    } else if let last = conversation.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: model.search) { _ in
                    matchIndex = 0
                    if let target = conversation.messages.first(where: { !model.search.isEmpty && $0.text.localizedCaseInsensitiveContains(model.search) }) {
                        followingLatest = false; matchIndex = 1
                        proxy.scrollTo(target.id, anchor: .center)
                    }
                }
                .onChange(of: model.histories[conversation.id]?.isLoading) { loading in
                    guard loading == false, model.histories[conversation.id]?.error == nil else { return }
                    if let target = historyScrollTarget {
                        proxy.scrollTo(target, anchor: .bottom); historyScrollTarget = nil
                    } else if initialHistoryPending {
                        initialHistoryPending = false
                        if let target = conversation.messages.first(where: { !model.search.isEmpty && $0.text.localizedCaseInsensitiveContains(model.search) }) {
                            matchIndex = 1; proxy.scrollTo(target.id, anchor: .center)
                        } else if let last = conversation.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: conversation.messages.last?.id) { id in if let id, followingLatest, model.search.isEmpty { proxy.scrollTo(id, anchor: .bottom) } }
            }
            composer(conversation)
        }
    }
    private func composer(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if model.canCompose(in: conversation.id) {
                if model.isDemo {
                    Text("Sample composer · Nothing is sent").font(.caption).foregroundStyle(.secondary)
                }
                if let photo = model.photoDrafts[conversation.id] {
                    OutgoingPhotoPreview(photo: photo, disabled: model.isBusy) { model.removePhoto(for: conversation.id) }
                    if !model.draft(for: conversation.id).isEmpty {
                        Text("Your text stays in the composer after sending this photo.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.photoErrors[conversation.id] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button { model.choosePhoto(for: conversation.id) } label: {
                        Image(systemName: "plus.circle").font(.system(size: 24)).foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Attach photo").accessibilityLabel("Attach photo")
                        .disabled(!model.canSelectPhoto(in: conversation.id)).padding(.bottom, 4)
                MessageComposer(text: Binding(get: { model.draft(for: conversation.id) },
                    set: { model.setDraft($0, for: conversation.id) }),
                    isEditable: model.sendingChatID != conversation.id,
                    onSubmit: { model.send(to: conversation.id) },
                    onHeightChange: { composerHeight = $0 })
                    .font(.body).frame(height: composerHeight)
                    .padding(.horizontal, 6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                    .overlay(alignment: .topLeading) {
                        if model.draft(for: conversation.id).isEmpty {
                            Text("Message…").font(.body).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 7).allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Message composer")
                    .disabled(model.sendingChatID == conversation.id)
                    .id(conversation.id)
                }
                if let result = model.sendResults[conversation.id], result != .accepted && result != .ready {
                    Text(result.message).font(.caption)
                        .foregroundStyle(result == .accepted ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if result == .permissionDenied {
                        Button("Open Automation settings") { model.openAutomationPrivacy() }
                    }
                    if result == .unknown {
                        Button("I checked the send status in Messages") { model.acknowledgeUnknown(for: conversation.id) }
                    }
                }
                HStack {
                    if model.preparingPhotoChatID != nil {
                        ProgressView().controlSize(.small)
                        Text("Preparing photo…").font(.caption)
                    } else if model.isSending {
                        ProgressView().controlSize(.small)
                        Text(model.sendingChatID == conversation.id ? "Sending to Messages…" : "Sending in another conversation…").font(.caption)
                    } else {
                        if model.sendResults[conversation.id] == .accepted {
                            Label("Sent to Messages", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                                .help(SendOutcome.accepted.message)
                        } else {
                            Text("Enter to send · Shift+Enter for a new line").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if model.draft(for: conversation.id).utf8.count > 14_000 {
                        Text("\(model.draft(for: conversation.id).utf8.count)/\(SendRequest.maximumBytes) B")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Button(model.photoDrafts[conversation.id] != nil ? (model.isDemo ? "Send sample photo" : "Send photo") : (model.isDemo ? "Send sample" : "Send")) { model.send(to: conversation.id) }
                        .buttonStyle(.borderedProminent).tint(accent)
                        .disabled(!model.canSend(to: conversation.id))
                }
            } else {
                Text(model.isLiveConnection ? "Sending is unavailable for this \(conversation.serviceLabel) conversation. Check the recipient and Messages connection." : "Imported databases are read-only. Use Connect Messages to send in your conversations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16)
    }
    private func openMessages() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
    private var helpView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("About Synapse").font(.title2.bold())
            Text("Synapse starts with your latest 2,000 messages. Opening a conversation loads its latest 1,000 messages. Use Load older messages to continue through local history. Recent messages refresh every five seconds.")
            Text("Loaded messages and drafts stay in memory until you quit or disconnect. Send delivers your text or selected photo through Apple Messages.")
            Text("Names come from Apple Messages, with Contacts as a fallback. Unsaved numbers remain numbers. Names stay in memory; Contacts and recipients stay unchanged.")
            Text("Reading names and sending require Automation access. A successful request is not a delivery receipt. Check uncertain send results in Messages.")
            Text("Enter sends, and Shift+Enter adds a new line. Enter confirms active input-method composition first. Click downloaded images to enlarge them.")
            Text("Read text and send text or photos in existing iMessage, SMS, and RCS conversations. New conversations, video and other file sending, reactions, editing, and deletion are not supported yet.")
            Text("Use + to choose one photo up to 20 MB, check the preview, and select Send photo. Your text remains available to send separately.")
            Text("SMS and RCS availability depends on Messages, your iPhone connection, and text message forwarding settings.")
            Text("An ad-hoc signed Apple Silicon test build. Not notarized.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("OK") { showHelp = false }.keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 570)
    }
}

#if !SYNAPSE_UI_TEST
@main
struct SynapseApp: App {
    @StateObject private var model = InboxModel()
    @StateObject private var telegram = TelegramModel()
    @NSApplicationDelegateAdaptor(SynapseApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("Synapse") {
            SynapseHubView(messages: model, telegram: telegram)
                .tint(Color(red: 0.43, green: 0.34, blue: 0.88))
                .onAppear { appDelegate.telegram = telegram }
        }
            .defaultSize(width: 1120, height: 760)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
#endif
