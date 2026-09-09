import SwiftUI
import AppKit

enum InboxPlatform: String, CaseIterable, Identifiable {
    case all = "All", messages = "Messages", telegram = "Telegram"
    var id: String { rawValue }
}

struct UnifiedConversation: Identifiable {
    let id: String
    let title: String
    let preview: String
    let date: Date
    let platform: InboxPlatform
}

struct SynapseHubView: View {
    @ObservedObject var messages: InboxModel
    @ObservedObject var telegram: TelegramModel
    @State private var platform = InboxPlatform.messages
    @State private var selected: String?
    @State private var search = ""
    @Environment(\.scenePhase) private var scenePhase
    private var conversations: [UnifiedConversation] {
        let apple = messages.isDemo ? [] : messages.conversations.map {
            UnifiedConversation(id: "apple:" + $0.id, title: $0.title, preview: $0.last.text,
                date: $0.last.date ?? .distantPast, platform: .messages)
        }
        let other = telegram.sortedChats.map {
            UnifiedConversation(id: "telegram:\($0.id)", title: $0.title, preview: $0.preview,
                date: $0.last?.date ?? .distantPast, platform: .telegram)
        }
        return (apple + other).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Synapse").font(.headline)
                Spacer()
                Picker("Inbox", selection: $platform) {
                    ForEach(InboxPlatform.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 310)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Local build").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            switch platform {
            case .messages: InboxView(model: messages)
            case .telegram: TelegramInboxView(model: telegram)
            case .all: unifiedInbox
            }
        }.frame(minWidth: 900, minHeight: 680)
            .onChange(of: platform) { platform in
                if platform == .all { messages.search = search; telegram.search = search }
                if platform == .messages { telegram.showChat(nil) }
            }
            .onChange(of: scenePhase) { phase in telegram.updateOnline(phase == .active) }
    }
    private var unifiedInbox: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack { Text("All conversations").font(.title2.bold()); Spacer() }.padding(20)
                TextField("Search loaded messages", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                    .onChange(of: search) { text in messages.search = text; telegram.search = text }
                List(selection: $selected) {
                    ForEach(conversations) { conversation in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: conversation.platform == .messages ? "message.fill" : "paperplane.fill")
                                .foregroundStyle(conversation.platform == .messages ? .green : .blue).frame(width: 28).padding(.top, 4)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conversation.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(conversation.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(conversation.platform.rawValue).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }.padding(.vertical, 7).tag(conversation.id)
                    }
                }.listStyle(.sidebar)
                HStack {
                    if messages.isDemo { Button("Connect Messages") { messages.connect() } }
                    Spacer()
                    if !telegram.isReady { Button("Connect Telegram") { platform = .telegram } }
                }.font(.caption).padding(16)
            }.navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            if selected?.hasPrefix("apple:") == true { InboxView(model: messages, detailOnly: true) }
            else if selected?.hasPrefix("telegram:") == true { TelegramInboxView(model: telegram, detailOnly: true) }
            else { Text("Choose a conversation from either messenger.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.onChange(of: selected) { id in
            if let id, id.hasPrefix("apple:") { messages.selectedID = String(id.dropFirst(6)); telegram.showChat(nil) }
            else if let id, id.hasPrefix("telegram:"), let chatID = Int64(id.dropFirst(9)) { telegram.selectedID = chatID; telegram.showChat(chatID) }
        }
    }
}

@MainActor
final class SynapseApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var telegram: TelegramModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let telegram, telegram.phase != .configuration else { return .terminateNow }
        Task {
            await telegram.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
