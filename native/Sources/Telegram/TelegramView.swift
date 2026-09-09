import SwiftUI
import AppKit

struct TelegramInboxView: View {
    @ObservedObject var model: TelegramModel
    var detailOnly = false
    var body: some View {
        Group {
            if detailOnly { detail }
            else {
                NavigationSplitView {
                    VStack(spacing: 0) {
                        HStack {
                            Label("Telegram", systemImage: "paperplane.fill").font(.title2.bold())
                            Spacer()
                            Text(model.isReady ? model.connection : "Not connected").font(.caption).foregroundStyle(.secondary)
                        }.padding(20)
                        TextField("Search conversations and messages", text: $model.search)
                            .textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                        List(selection: $model.selectedID) {
                            ForEach(model.sortedChats) { chat in
                                HStack(spacing: 10) {
                                    TelegramAvatar(model: model, chat: chat)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(chat.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                        Text(chat.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                    if chat.unread > 0 { Text("\(chat.unread)").font(.caption2).padding(5).background(.blue.opacity(0.15), in: Capsule()) }
                                }.padding(.vertical, 7).tag(chat.id)
                            }
                        }.listStyle(.sidebar)
                        if model.isReady {
                            HStack {
                                if model.hasMoreChats {
                                    Button("Load more chats") { model.loadChats() }.disabled(model.loadingChats)
                                }
                                Spacer()
                                Button("Disconnect") { Task { await model.disconnect() } }.disabled(!model.sending.isEmpty)
                            }.font(.caption).padding(16)
                        }
                        if let error = model.error, model.isReady { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 12) }
                        Text("Independent Telegram client").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 12)
                    }.navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                } detail: { detail }
            }
        }.frame(minWidth: detailOnly ? 540 : 900, minHeight: 580)
            .onChange(of: model.selectedID) { id in model.showChat(id) }
            .onDisappear { model.showChat(nil) }
    }
    @ViewBuilder private var detail: some View {
        if !model.isReady { TelegramConnectView(model: model) }
        else if let id = model.selectedID, let chat = model.chats[id] {
            TelegramConversationView(model: model, chat: chat).id(id)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "paperplane").font(.system(size: 42)).foregroundStyle(.blue)
                Text("Your Telegram conversations").font(.title2.bold())
                Text(model.loadingChats ? "Loading chats…" : "Choose a conversation to get started.").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TelegramConnectView: View {
    @ObservedObject var model: TelegramModel
    @State private var apiID = ""
    @State private var apiHash = ""
    @State private var input = ""
    @State private var useNewCredentials = false
    var body: some View {
        GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            if model.phase != .qr { Image(systemName: "paperplane.circle.fill").font(.system(size: 52)).foregroundStyle(.blue) }
            Text(title).font(.title.bold())
            if model.phase == .configuration {
                Text("Bring your Telegram chats into Synapse.").foregroundStyle(.secondary)
                if model.hasSavedCredentials && !useNewCredentials {
                    Button("Connect saved Telegram account") { model.connect() }.buttonStyle(.borderedProminent)
                    Button("Use different API credentials") { useNewCredentials = true }.buttonStyle(.link)
                } else {
                    TextField("API ID", text: $apiID).textFieldStyle(.roundedBorder).accessibilityLabel("Telegram API ID")
                    SecureField("API hash", text: $apiHash).textFieldStyle(.roundedBorder).accessibilityLabel("Telegram API hash")
                    Button("Continue") {
                        model.connect(apiID: apiID, apiHash: apiHash)
                        if model.phase != .configuration { apiID = ""; apiHash = "" }
                    }.buttonStyle(.borderedProminent).disabled(apiID.isEmpty || apiHash.isEmpty)
                    Link("Get API credentials", destination: URL(string: "https://my.telegram.org/apps")!)
                }
                Text("API credentials and the database key stay in this Mac’s Keychain. Chats are cached in Synapse’s private data folder.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.phase == .qr {
                Text("1. Open Telegram on your phone.\n2. Go to Settings → Devices → Link Desktop Device.\n3. Scan this QR code to sign in.").foregroundStyle(.secondary)
                if let link = model.qrLink {
                    TelegramLoginQRView(link: link).id(link).frame(maxWidth: .infinity)
                }
                Text("Keep this window open. The QR code refreshes automatically. If you use two-step verification, you’ll enter your password after scanning.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if [.phone, .code, .password, .email, .emailCode].contains(model.phase) {
                if model.phase == .phone {
                    Button { input = ""; model.requestQRCode() } label: { Label("Log in with QR code", systemImage: "qrcode") }
                        .buttonStyle(.borderedProminent).disabled(!model.canRequestQRCode)
                    Text("Or use your phone number").font(.caption).foregroundStyle(.secondary)
                }
                Text(instructions).foregroundStyle(.secondary)
                if [.password, .code, .emailCode].contains(model.phase) {
                    SecureField(placeholder, text: $input).textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }.accessibilityLabel(placeholder)
                } else {
                    TextField(placeholder, text: $input).textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }.accessibilityLabel(placeholder)
                }
                Button("Continue") { submit() }.buttonStyle(.borderedProminent).disabled(input.isEmpty || model.busy)
                if [.code, .emailCode].contains(model.phase) {
                    if let delivery = model.codeDelivery, let method = delivery.nextMethod {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = delivery.remaining(at: context.date) ?? 0
                            Button(model.resendRequested ? "Code requested — waiting for Telegram" : remaining > 0 ? "Resend via \(method) in \(remaining)s" : "Resend code via \(method)") {
                                input = ""; model.resendCode()
                            }.disabled(!model.canResendCode(at: context.date))
                        }
                    } else {
                        Text("Telegram has not offered another code yet. You can switch to QR login below.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.phase != .phone {
                    Button { input = ""; model.requestQRCode() } label: { Label("Log in with QR code instead", systemImage: "qrcode") }
                        .disabled(!model.canRequestQRCode)
                }
                Text("Verification codes and passwords are used for this sign-in only.").font(.caption).foregroundStyle(.secondary)
            } else if model.phase == .unsupported {
                Text("This account needs an additional sign-in step. Complete it in the official Telegram app, then reconnect.")
                Button("Open Telegram") { NSWorkspace.shared.open(URL(string: "https://web.telegram.org/")!) }
            } else {
                ProgressView().controlSize(.small)
                Text(model.phase == .closing ? "Closing the encrypted session…" : "Connecting securely…").foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if model.phase != .configuration && model.phase != .closing {
                Button("Cancel connection") { input = ""; Task { await model.disconnect() } }.disabled(model.busy)
            }
        }.padding(40).frame(maxWidth: 480).frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        }
            .task { if model.phase == .configuration { model.checkSavedCredentials() } }
            .onChange(of: model.phase) { _ in input = "" }
            .onDisappear { input = ""; apiID = ""; apiHash = "" }
    }
    private func submit() {
        guard !input.isEmpty, !model.busy else { return }
        model.authenticate(input); input = ""
    }
    private var title: String {
        switch model.phase {
        case .phone: return "Your phone number"
        case .qr: return "Log in with QR code"
        case .code, .emailCode: return "Verification code"
        case .password: return "Two-step verification"
        case .email: return "Your email address"
        case .ready: return "Telegram connected"
        case .closing: return "Disconnecting"
        default: return "Connect Telegram"
        }
    }
    private var placeholder: String {
        switch model.phase {
        case .phone: return "Phone number with country code"
        case .password: return "Two-step verification password"
        case .email: return "Email address"
        default: return "Verification code"
        }
    }
    private var instructions: String {
        switch model.phase {
        case .phone: return "Use the phone number registered with your Telegram account, including + and the country code."
        case .password: return "Enter the password you set up in Telegram."
        case .email: return "Telegram requires an email address to continue this sign-in."
        case .code, .emailCode: return model.codeDelivery?.instructions ?? "Choose QR login if your code has not arrived."
        default: return ""
        }
    }
}

private struct TelegramLoginQRView: View {
    let link: String
    var body: some View {
        Group {
            if let image = TelegramLoginQR.image(for: link) {
                Image(decorative: image, scale: 1).interpolation(.none)
                    .frame(width: 264, height: 264).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(false)
                    .accessibilityLabel("Telegram login QR code. Scan with your phone’s Telegram app.")
            } else {
                Text("Unable to display the QR code. Cancel the connection and try again.").foregroundStyle(.orange)
            }
        }
    }
}

struct TelegramAvatar: View {
    @ObservedObject var model: TelegramModel
    let chat: TelegramChat
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Circle().fill(.blue.opacity(0.12))
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else { Text(NamePresentation.initials(for: chat.title) ?? "T").font(.system(size: 13, weight: .semibold)).foregroundStyle(.blue) }
        }.frame(width: 36, height: 36).clipShape(Circle())
            .task(id: "\(chat.id)-\(chat.photo?.id ?? 0)-\(model.files[chat.photo?.id ?? 0]?.path ?? "")") {
                image = nil
                guard let file = chat.photo else { return }
                if let path = model.files[file.id]?.path {
                    let attachment = MessageAttachment(id: file.id, filename: path, mimeType: "image/jpeg", name: "Telegram profile photo")
                    let root = model.storage.root
                    let result = await Task.detached { AttachmentImageLoader.image(for: attachment, root: root) }.value
                    if !Task.isCancelled { image = result }
                } else { model.download(file) }
            }
    }
}

struct TelegramConversationView: View {
    @ObservedObject var model: TelegramModel
    let chat: TelegramChat
    @State private var composerHeight: CGFloat = 32
    @State private var followingLatest = true
    @State private var olderAnchor: Int64?
    @State private var matchIndex = 0
    @State private var visibleMessages = Set<Int64>()
    @State private var viewportHeight: CGFloat = 0
    private var messages: [TelegramMessage] { model.histories[chat.id]?.messages ?? chat.last.map { [$0] } ?? [] }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TelegramAvatar(model: model, chat: chat)
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.title).font(.title2.bold()).textSelection(.enabled)
                    Text(model.activity[chat.id] ?? "Telegram · \(messages.count) messages loaded").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "https://web.telegram.org/")!) { Image(systemName: "arrow.up.right.square") }.help("Open Telegram")
            }.padding(22)
            Divider()
            ScrollViewReader { proxy in
                HStack {
                    let history = model.histories[chat.id]
                    Button(history?.error == nil ? "Load older messages" : "Retry history") {
                        followingLatest = false; olderAnchor = messages.first?.id
                        model.loadHistory(chat.id, older: true)
                    }.disabled(history?.loading == true || history?.hasMore == false)
                    ZStack { if history?.loading == true { ProgressView().controlSize(.small) } }.frame(width: 16, height: 16)
                    if history?.hasMore == false { Text("All available history loaded").foregroundStyle(.secondary) }
                    if let error = history?.error { Text(error).foregroundStyle(.orange).lineLimit(1) }
                    Spacer()
                    if !model.search.isEmpty {
                        Button("Next match") {
                            let matches = messages.filter { $0.text.localizedCaseInsensitiveContains(model.search) }
                            guard !matches.isEmpty else { return }
                            followingLatest = false; proxy.scrollTo(matches[matchIndex % matches.count].id, anchor: .center); matchIndex += 1
                        }
                    }
                    Button("Latest") { followingLatest = true; if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }.font(.caption).padding(.horizontal, 22).padding(.vertical, 8)
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(messages) { message in
                            bubble(message).id(message.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: TelegramMessageFrames.self,
                                        value: [message.id: geometry.frame(in: .named("telegramViewport"))])
                                })
                        }
                    }.padding(22)
                }
                .coordinateSpace(name: "telegramViewport")
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { viewportHeight = geometry.size.height }
                        .onChange(of: geometry.size.height) { viewportHeight = $0 }
                })
                .onPreferenceChange(TelegramMessageFrames.self) { frames in
                    let visible = Set(frames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }.keys)
                    let new = visible.subtracting(visibleMessages)
                    visibleMessages = visible
                    for message in messages where new.contains(message.id) { model.markVisible(message) }
                }
                .onChange(of: model.histories[chat.id]?.loading) { loading in
                    guard loading == false else { return }
                    if let anchor = olderAnchor { proxy.scrollTo(anchor, anchor: .bottom); olderAnchor = nil }
                    else if followingLatest, let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: messages.last?.id) { id in if followingLatest, let id { proxy.scrollTo(id, anchor: .bottom) } }
                .onChange(of: model.search) { _ in matchIndex = 0 }
                .task {
                    await Task.yield()
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            composer
            Divider()
            HStack {
                Circle().fill(model.connection == "Connected" ? .green : .orange).frame(width: 6, height: 6)
                Text(model.connection)
                Spacer()
                Text("Telegram · Local cache")
            }.font(.caption).foregroundStyle(.secondary).frame(height: 16).padding(12)
        }.task { model.showChat(chat.id); model.loadHistory(chat.id) }
            .onDisappear { model.hideChat(chat.id) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                for message in messages where visibleMessages.contains(message.id) { model.markVisible(message) }
            }
    }
    private func bubble(_ message: TelegramMessage) -> some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 70) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 5) {
                if chat.isGroup && !message.isOutgoing { Text(model.senderName(message)).font(.caption2).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 8) {
                    if !message.text.isEmpty { Text(message.text).font(.system(size: 14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if let file = message.photo, message.linkPreview == nil { TelegramPhotoView(model: model, file: file) }
                    if let preview = message.linkPreview {
                        TelegramLinkPreviewCard(model: model, preview: preview, isOutgoing: message.isOutgoing)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
                    .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                    .background(message.isOutgoing ? Color.blue : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(!model.search.isEmpty && message.text.localizedCaseInsensitiveContains(model.search) ? Color.orange : .clear, lineWidth: 2))
                HStack(spacing: 5) {
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    if message.isOutgoing {
                        Text(message.failed ? "Failed" : message.sending ? "Sending…" : message.id <= chat.lastReadOutbox ? "Read" : "Sent")
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: 540, alignment: message.isOutgoing ? .trailing : .leading)
            if !message.isOutgoing { Spacer(minLength: 70) }
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if chat.canSendText || chat.canSendPhotos {
                if let photo = model.photos[chat.id] {
                    OutgoingPhotoPreview(photo: photo, disabled: model.sending.contains(chat.id) || model.uncertain.contains(chat.id)) { model.removePhoto(chat.id) }
                    if !model.draft(chat.id).isEmpty { Text("Your text stays in the composer after sending this photo.").font(.caption).foregroundStyle(.secondary) }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    Button { model.choosePhoto(chat.id) } label: { Image(systemName: "plus.circle").font(.system(size: 24)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Attach Telegram photo")
                        .disabled(!chat.canSendPhotos || model.sending.contains(chat.id) || model.uncertain.contains(chat.id)).padding(.bottom, 4)
                    MessageComposer(text: Binding(get: { model.draft(chat.id) }, set: { model.setDraft($0, chatID: chat.id) }),
                        isEditable: !model.sending.contains(chat.id), onSubmit: { model.send(chat.id) }, onHeightChange: { composerHeight = $0 })
                        .frame(height: composerHeight).padding(.horizontal, 6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        .overlay(alignment: .topLeading) {
                            if model.draft(chat.id).isEmpty { Text("Message…").foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 7).allowsHitTesting(false) }
                        }
                }
                HStack {
                    Text(model.sendStatus[chat.id] ?? "Enter to send · Shift+Enter for a new line").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.photos[chat.id] == nil ? "Send" : "Send photo") { model.send(chat.id) }
                        .buttonStyle(.borderedProminent).tint(.blue).disabled(!model.canSend(chat.id))
                }.frame(minHeight: 24)
                if model.uncertain.contains(chat.id) { Button("I checked the send status in Telegram") { model.acknowledgeUnknown(chat.id) }.font(.caption) }
            } else { Text("You can read this conversation. Telegram does not allow this account to post here.").font(.caption).foregroundStyle(.secondary) }
        }.padding(16)
    }
}

private struct TelegramMessageFrames: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TelegramPhotoView: View {
    @ObservedObject var model: TelegramModel
    let file: TelegramFile
    @State private var image: CGImage?
    @State private var expanded = false
    var body: some View {
        Group {
            if let image {
                Button { expanded = true } label: {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxWidth: 320, maxHeight: 300).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("Telegram photo")
            } else {
                Button { model.download(file) } label: { Label("Load photo", systemImage: "photo") }
                    .frame(width: 160, height: 100).buttonStyle(.plain)
            }
        }.task(id: model.files[file.id]?.path) {
            guard let path = model.files[file.id]?.path else { model.download(file); return }
            let attachment = MessageAttachment(id: file.id, filename: path, mimeType: "image/jpeg", name: "Telegram photo")
            let root = model.storage.root
            let result = await Task.detached { AttachmentImageLoader.image(for: attachment, root: root) }.value
            if !Task.isCancelled { image = result }
        }.sheet(isPresented: $expanded) {
            VStack {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                Button("Close") { expanded = false }.keyboardShortcut(.cancelAction)
            }.padding(20).frame(width: 760, height: 580)
        }
    }
}

struct TelegramLinkPreviewCard: View {
    @ObservedObject var model: TelegramModel
    let preview: TelegramLinkPreview
    let isOutgoing: Bool
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @State private var pendingLink: TelegramLinkDestination?

    var body: some View {
        Button {
            guard let url = preview.destinationURL else { return }
            if preview.skipConfirmation { openURL(url) }
            else { pendingLink = TelegramLinkDestination(url: url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let photo = preview.photo {
                    TelegramLinkThumbnailView(model: model, file: photo)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !preview.siteName.isEmpty {
                        Text(preview.siteName.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isOutgoing ? Color.white.opacity(0.85) : Color.blue)
                    }
                    if !preview.title.isEmpty {
                        Text(preview.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isOutgoing ? Color.white : Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if !preview.description.isEmpty {
                        Text(preview.description)
                            .font(.system(size: 12))
                            .foregroundStyle(isOutgoing ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(
                isOutgoing ? Color.white.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.8),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isOutgoing ? Color.white.opacity(0.2) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(preview.destinationURL == nil)
        .help(preview.destinationURL?.absoluteString ?? "This preview has no supported web address.")
        .sheet(item: $pendingLink) { destination in
            VStack(alignment: .leading, spacing: 16) {
                Text("Open this link?").font(.title2.bold())
                Text("This link will open in your browser.").foregroundStyle(.secondary)
                ScrollView {
                    Text(destination.url.absoluteString).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
                HStack {
                    Spacer()
                    Button("Cancel") { pendingLink = nil }.keyboardShortcut(.cancelAction)
                    Button("Open link") {
                        pendingLink = nil
                        openURL(destination.url)
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 460)
        }
    }
}

private struct TelegramLinkDestination: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct TelegramLinkThumbnailView: View {
    @ObservedObject var model: TelegramModel
    let file: TelegramFile
    @State private var image: CGImage?

    var body: some View {
        // A real container/placeholder must exist before the image loads so the
        // task can start. A conditional-only Group has no initial child to run it.
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(false)
                    .accessibilityLabel("Telegram link preview thumbnail")
            } else {
                Label("Preview image", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 160, height: 90)
            }
        }
        .padding(6)
        .task(id: "\(file.id)-\(model.files[file.id]?.path ?? "")") {
            image = nil
            guard let path = model.files[file.id]?.path else { model.download(file); return }
            let attachment = MessageAttachment(id: file.id, filename: path, mimeType: "image/jpeg", name: "Telegram link preview thumbnail")
            let root = model.storage.root
            let result = await Task.detached { AttachmentImageLoader.image(for: attachment, root: root) }.value
            if !Task.isCancelled { image = result }
        }
    }
}
