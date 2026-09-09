import Foundation

extension Dictionary where Key == String, Value == Any {
    func object(_ key: String) -> TelegramObject { self[key] as? TelegramObject ?? [:] }
    func objects(_ key: String) -> [TelegramObject] { self[key] as? [TelegramObject] ?? [] }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func number(_ key: String) -> Int64 {
        if let value = self[key] as? NSNumber { return value.int64Value }
        return Int64(self[key] as? String ?? "") ?? 0
    }
    func flag(_ key: String) -> Bool { self[key] as? Bool ?? false }
}

enum TelegramPhase: Equatable {
    case configuration, connecting, phone, qr, code, password, email, emailCode, ready, closing, unsupported
}

struct TelegramFile: Equatable {
    let id: Int64
    let path: String?
    let size: Int64
    init(_ object: TelegramObject) {
        id = object.number("id")
        size = max(object.number("size"), object.number("expected_size"))
        let local = object.object("local")
        path = local.flag("is_downloading_completed") && !local.string("path").isEmpty ? local.string("path") : nil
    }
}

struct TelegramLinkPreview: Equatable {
    let url: String
    let displayURL: String
    let siteName: String
    let title: String
    let description: String
    let photo: TelegramFile?
    let skipConfirmation: Bool
    init?(_ object: TelegramObject) {
        guard !object.isEmpty else { return nil }
        url = object.string("url")
        displayURL = object.string("display_url")
        siteName = object.string("site_name")
        title = object.string("title")
        skipConfirmation = object.flag("skip_confirmation")
        let descObj = object.object("description")
        description = descObj.isEmpty ? object.string("description") : descObj.string("text")
        let rawPhoto = object.object("type").object("photo").isEmpty ? object.object("photo") : object.object("type").object("photo")
        photo = TelegramMessage.photoFile(rawPhoto)
        guard !url.isEmpty || !title.isEmpty || !siteName.isEmpty || !description.isEmpty || photo != nil else { return nil }
    }
    var destinationURL: URL? {
        // display_url is a presentation label, not a navigation target.
        guard let components = URLComponents(string: url),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }
}

struct TelegramMessage: Identifiable, Equatable {
    let id: Int64
    let chatID: Int64
    let senderID: Int64
    let senderIsChat: Bool
    let date: Date
    let isOutgoing: Bool
    var text: String
    var photo: TelegramFile?
    var linkPreview: TelegramLinkPreview?
    var sending: Bool
    var failed: Bool
    var expiresAt: Date?
    init(_ object: TelegramObject, now: Date = Date()) {
        id = object.number("id"); chatID = object.number("chat_id")
        let sender = object.object("sender_id")
        senderIsChat = sender.string("@type") == "messageSenderChat"
        senderID = sender.number(senderIsChat ? "chat_id" : "user_id")
        date = Date(timeIntervalSince1970: TimeInterval(object.number("date")))
        isOutgoing = object.flag("is_outgoing")
        let state = object.object("sending_state").string("@type")
        sending = state == "messageSendingStatePending"
        failed = state == "messageSendingStateFailed"
        let remaining = (object["auto_delete_in"] as? Double) ?? 0
        expiresAt = remaining > 0 ? now.addingTimeInterval(remaining) : nil
        let content = object.object("content")
        let protected = !object.object("self_destruct_type").isEmpty || !content.object("self_destruct_type").isEmpty
        let parsed = Self.content(content, selfDestructing: protected)
        text = parsed.0; photo = parsed.1; linkPreview = parsed.2
    }
    static func content(_ content: TelegramObject, selfDestructing: Bool = false) -> (String, TelegramFile?, TelegramLinkPreview?) {
        if selfDestructing { return ("Self-destructing message · Open in Telegram", nil, nil) }
        switch content.string("@type") {
        case "messageText":
            let preview = content.object("link_preview").isEmpty ? content.object("web_page") : content.object("link_preview")
            let linkPreview = TelegramLinkPreview(preview)
            let photo = linkPreview?.photo
            return (content.object("text").string("text"), photo, linkPreview)
        case "messagePhoto": return (content.object("caption").string("text"), photoFile(content.object("photo")), nil)
        case "messageVideo": return ("Video" + caption(content), nil, nil)
        case "messageAnimation": return ("Animation" + caption(content), nil, nil)
        case "messageDocument": return ("File: " + content.object("document").string("file_name") + caption(content), nil, nil)
        case "messageVoiceNote": return ("Voice message" + caption(content), nil, nil)
        case "messageVideoNote": return ("Video message", nil, nil)
        case "messageSticker": return (content.object("sticker").string("emoji") + " Sticker", nil, nil)
        case "messagePoll": return (content.object("poll").object("question").string("text"), nil, nil)
        case "messageCall": return ("Call", nil, nil)
        default: return ("Message · Open in Telegram", nil, nil)
        }
    }
    private static func caption(_ object: TelegramObject) -> String {
        let text = object.object("caption").string("text")
        return text.isEmpty ? "" : "\n" + text
    }
    static func photoFile(_ photo: TelegramObject) -> TelegramFile? {
        let sizes = photo.objects("sizes")
        guard let size = sizes.max(by: { $0.number("width") * $0.number("height") < $1.number("width") * $1.number("height") }) else { return nil }
        let file = TelegramFile(size.object("photo"))
        return file.id > 0 ? file : nil
    }
}

struct TelegramChat: Identifiable, Equatable {
    let id: Int64
    var title: String
    var photo: TelegramFile?
    var last: TelegramMessage?
    var order: Int64
    var unread: Int
    var lastReadOutbox: Int64
    var canSendText: Bool
    var canSendPhotos: Bool
    let isGroup: Bool
    var preview: String { last.map { $0.text.isEmpty ? "Photo" : $0.text } ?? "No messages" }
    init(_ object: TelegramObject) {
        id = object.number("id"); title = object.string("title")
        let small = TelegramFile(object.object("photo").object("small"))
        photo = small.id > 0 ? small : nil
        last = object.object("last_message").isEmpty ? nil : TelegramMessage(object.object("last_message"))
        order = object.objects("positions").map { $0.number("order") }.max() ?? 0
        unread = Int(object.number("unread_count")); lastReadOutbox = object.number("last_read_outbox_message_id")
        canSendText = object.object("permissions").flag("can_send_basic_messages")
        canSendPhotos = object.object("permissions").flag("can_send_photos")
        isGroup = ["chatTypeBasicGroup", "chatTypeSupergroup"].contains(object.object("type").string("@type"))
    }
}

struct TelegramHistory {
    var messages: [TelegramMessage] = []
    var oldestID: Int64 = 0
    var hasMore = true
    var loaded = false
    var loading = false
    var error: String?
    mutating func merge(_ page: [TelegramMessage]) {
        var messages = Dictionary(self.messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for message in page { messages[message.id] = message }
        self.messages = messages.values.sorted { $0.id < $1.id }
    }
}
