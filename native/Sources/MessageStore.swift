import Foundation
import SQLite3

struct MessageAttachment: Identifiable, Sendable, Equatable {
    let id: Int64
    let filename: String?
    let mimeType: String?
    let name: String
    var isLinkPayload: Bool {
        ((filename ?? name) as NSString).pathExtension.lowercased() == "pluginpayloadattachment"
    }
    var displayName: String { isLinkPayload ? "Link preview" : name }
    var isImage: Bool {
        isLinkPayload || mimeType?.lowercased().hasPrefix("image/") == true ||
            ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"].contains(
                ((filename ?? name) as NSString).pathExtension.lowercased())
    }
}

struct ChatMessage: Identifiable, Sendable, Equatable {
    let id: String
    let conversationID: String
    let conversationTitle: String
    let sender: String
    let text: String
    let date: Date?
    let isFromMe: Bool
    let bodyUnavailable: Bool
    let hasAttachment: Bool
    var conversationService: String? = nil
    var conversationAddress: String? = nil
    var conversationDisplayName: String? = nil
    var attachments: [MessageAttachment] = []
    var linkPreview: LinkPreviewMetadata? = nil
    var sourceRowID: Int64 = 0
    var visibleAttachments: [MessageAttachment] {
        guard let index = linkPreview?.imageIndex, attachments.indices.contains(index), attachments[index].isLinkPayload else { return attachments }
        return attachments.enumerated().compactMap { offset, attachment in
            !attachment.isLinkPayload || offset == index ? attachment : nil
        }
    }
}

struct LinkPreviewMetadata: Sendable, Equatable {
    let title: String?
    let imageIndex: Int?
}

enum LinkPreviewDecoder {
    static func decode(_ data: Data) -> LinkPreviewMetadata? {
        // Decode property-list structure only. Never instantiate archived/private classes.
        // XML exposes archive UID references as ordinary CF$UID dictionaries.
        guard data.count <= 262_144,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              xml.count <= 2_097_152,
              let document = try? XMLDocument(data: xml, options: .nodeLoadExternalEntitiesNever),
              let root = document.rootElement()?.children?.first(where: { $0.name == "dict" }) else { return nil }
        func value(_ key: String, in node: XMLNode) -> XMLNode? {
            let children = node.children ?? []
            guard let position = children.firstIndex(where: { $0.name == "key" && $0.stringValue == key }),
                  children.indices.contains(position + 1) else { return nil }
            return children[position + 1]
        }
        guard let objects = value("$objects", in: root)?.children, objects.count <= 2048 else { return nil }
        func resolve(_ node: XMLNode?) -> XMLNode? {
            guard let node else { return nil }
            guard let uid = value("CF$UID", in: node)?.stringValue.flatMap(Int.init) else { return node }
            return objects.indices.contains(uid) ? objects[uid] : nil
        }
        guard let wrapper = objects.first(where: { value("richLinkMetadata", in: $0) != nil }),
              let metadata = resolve(value("richLinkMetadata", in: wrapper)) else { return nil }
        let titleNode = resolve(value("title", in: metadata))
        let title = titleNode?.name == "string" ? titleNode?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let image = resolve(value("image", in: metadata))
        let imageIndex = image.flatMap { value("richLinkImageAttachmentSubstituteIndex", in: $0)?.stringValue.flatMap(Int.init) }
        return LinkPreviewMetadata(title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(400)) },
            imageIndex: imageIndex.flatMap { (0..<100).contains($0) ? $0 : nil })
    }
}

struct Conversation: Identifiable {
    let id: String
    let title: String
    let messages: [ChatMessage]
    var last: ChatMessage { messages[messages.count - 1] }
    var service: String? { last.conversationService }
    var serviceLabel: String {
        service ?? (id.hasPrefix("iMessage;") ? "iMessage" : "Messages")
    }
}

struct Snapshot: Sendable {
    let messages: [ChatMessage]
    let sourceRows: Int
    let limit: Int
    var hasMore: Bool = false
    var oldestRowID: Int64? { messages.map(\.sourceRowID).filter { $0 > 0 }.min() }
    var unavailableCount: Int { messages.filter(\.bodyUnavailable).count }
}

enum StoreError: Error, LocalizedError {
    case unavailable, schema, query
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Unable to open the Messages database. Check Full Disk Access and the file location."
        case .schema: return "This database format is not supported. Select a macOS Messages chat.db file."
        case .query: return "Unable to read messages. The database may be busy or use an unsupported format. Please try again."
        }
    }
}

// A bounded extractor for the first NSString in a standard NSAttributedString typedstream.
// It never constructs archived classes or executes an object unarchiver.
// Unknown encodings return nil instead of guessing or exposing archive metadata as text.
enum BodyDecoder {
    static func visibleText(_ text: String?) -> String? {
        // Messages uses noncharacters FFFE/FFFF as well as FFFC for rich content.
        // They are transport markers, not printable message text or emoji.
        text?.replacingOccurrences(of: "\u{fffc}", with: "")
            .replacingOccurrences(of: "\u{fffe}", with: "")
            .replacingOccurrences(of: "\u{ffff}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func text(from data: Data) -> String? {
        let b = [UInt8](data)
        let header = Array("streamtyped".utf8)
        guard b.count >= 20, b.count <= 2_097_152,
              b[0] == 4, b[1] == 11, Array(b[2..<13]) == header else { return nil }
        func locate(_ pattern: [UInt8], from start: Int, through end: Int) -> Int? {
            guard start >= 0, end >= start, pattern.count <= b.count else { return nil }
            let upper = min(end, b.count - pattern.count)
            guard start <= upper else { return nil }
            for i in start...upper {
                if Array(b[i..<(i + pattern.count)]) == pattern { return i }
            }
            return nil
        }
        guard locate(Array("NSAttributedString".utf8), from: 13, through: 100) != nil ||
              locate(Array("NSMutableAttributedString".utf8), from: 13, through: 100) != nil,
              let stringClass = locate(Array("NSString".utf8), from: 13, through: 160),
              let marker = locate([0x84, 0x01, 0x2b], from: stringClass + 8, through: stringClass + 32) else { return nil }
        var p = marker + 3
        guard p < b.count else { return nil }
        let tag = b[p]; p += 1
        let length: Int
        switch tag {
        case 0...127: length = Int(tag)
        case 0x81:
            guard p + 2 <= b.count else { return nil }
            length = Int(b[p]) | (Int(b[p + 1]) << 8); p += 2
        case 0x82:
            guard p + 4 <= b.count else { return nil }
            length = (0..<4).reduce(0) { $0 | (Int(b[p + $1]) << ($1 * 8)) }; p += 4
        default: return nil
        }
        guard length <= 1_048_576, p + length < b.count, b[p + length] == 0x86 else { return nil }
        return String(bytes: b[p..<(p + length)], encoding: .utf8)
    }
}

enum MessageStore {
    static func date(_ raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        let seconds = (raw > 1_000_000_000_000 || raw < -1_000_000_000_000) ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSince1970: seconds + 978_307_200)
    }

    static func load(path: String, limit: Int = 2000, conversationID: String? = nil, beforeRowID: Int64? = nil) throws -> Snapshot {
        guard (1...10000).contains(limit), beforeRowID.map({ $0 > 0 }) ?? true else { throw StoreError.query }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection = db else { if let db { sqlite3_close(db) }; throw StoreError.unavailable }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 1500)
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 4_194_304)
        sqlite3_exec(connection, "PRAGMA query_only=ON", nil, nil, nil)
        func columns(_ table: String) throws -> Set<String> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { throw StoreError.unavailable }
            defer { sqlite3_finalize(statement) }
            var result = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(statement, 1) { result.insert(String(cString: ptr)) }
            }
            return result
        }
        let m = try columns("message"), c = try columns("chat"), j = try columns("chat_message_join"), h = try columns("handle")
        guard Set(["guid", "text", "date", "is_from_me"]).isSubset(of: m), c.contains("guid"),
              Set(["message_id", "chat_id"]).isSubset(of: j) else { throw StoreError.schema }
        let rich = m.contains("attributedBody") ? "m.attributedBody" : "NULL"
        let attachment = m.contains("cache_has_attachments") ? "m.cache_has_attachments" : "0"
        let display = c.contains("display_name") ? "c.display_name" : "NULL"
        let identifier = c.contains("chat_identifier") ? "c.chat_identifier" : "NULL"
        let service = c.contains("service_name") ? "c.service_name" : "NULL"
        let payload = m.contains("payload_data") ? "m.payload_data" : "NULL"
        let handles = m.contains("handle_id") && h.contains("id")
        let sender = handles ? "h.id" : "NULL"
        let handleJoin = handles ? "LEFT JOIN handle h ON h.ROWID=m.handle_id" : ""
        var filters = ["1=1"]
        if m.contains("associated_message_type") { filters.append("COALESCE(associated_message_type,0)=0") }
        if m.contains("item_type") { filters.append("COALESCE(item_type,0)=0") }
        if conversationID != nil {
            filters.append("ROWID IN (SELECT cj.message_id FROM chat_message_join cj JOIN chat target ON target.ROWID=cj.chat_id WHERE target.guid=?)")
        }
        if beforeRowID != nil { filters.append("ROWID < ?") }
        let selection = "SELECT ROWID FROM message WHERE \(filters.joined(separator: " AND ")) ORDER BY ROWID DESC LIMIT ?"
        func bindPage(_ statement: OpaquePointer?) {
            var index: Int32 = 1
            if let conversationID {
                sqlite3_bind_text(statement, index, conversationID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); index += 1
            }
            if let beforeRowID { sqlite3_bind_int64(statement, index, beforeRowID); index += 1 }
            // One extra source row tells us whether an older page exists.
            sqlite3_bind_int(statement, index, Int32(limit + 1))
        }
        var attachmentsByMessage: [Int64: [MessageAttachment]] = [:]
        let a = try columns("attachment"), aj = try columns("message_attachment_join")
        if a.contains("filename"), Set(["message_id", "attachment_id"]).isSubset(of: aj) {
            let mime = a.contains("mime_type") ? "a.mime_type" : "NULL"
            let name = a.contains("transfer_name") ? "a.transfer_name" : "NULL"
            let attachmentSQL = """
            SELECT DISTINCT j.message_id,a.ROWID,a.filename,\(mime),\(name)
            FROM message_attachment_join j JOIN attachment a ON a.ROWID=j.attachment_id
            WHERE j.message_id IN (\(selection))
            ORDER BY j.message_id,a.ROWID
            """
            var attachmentStatement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, attachmentSQL, -1, &attachmentStatement, nil) == SQLITE_OK else { throw StoreError.query }
            defer { sqlite3_finalize(attachmentStatement) }
            bindPage(attachmentStatement)
            func attachmentString(_ column: Int32) -> String? {
                sqlite3_column_text(attachmentStatement, column).map { String(cString: $0) }
            }
            while true {
                let code = sqlite3_step(attachmentStatement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw StoreError.query }
                let filename = attachmentString(2)
                let attachment = MessageAttachment(id: sqlite3_column_int64(attachmentStatement, 1),
                    filename: filename, mimeType: attachmentString(3),
                    name: attachmentString(4) ?? filename.map { ($0 as NSString).lastPathComponent } ?? "Attachment")
                attachmentsByMessage[sqlite3_column_int64(attachmentStatement, 0), default: []].append(attachment)
            }
        }
        let sql = """
        WITH page AS (SELECT ROWID AS source_id,* FROM message WHERE ROWID IN (\(selection)))
        SELECT m.source_id,m.guid,m.text,m.date,m.is_from_me,\(rich),\(attachment),
               c.ROWID,c.guid,\(display),\(identifier),\(sender),\(service),\(payload)
        FROM page m LEFT JOIN chat_message_join j ON j.message_id=m.source_id
        LEFT JOIN chat c ON c.ROWID=j.chat_id \(handleJoin)
        \(conversationID == nil ? "" : "WHERE c.guid=?")
        ORDER BY m.date,m.source_id,c.ROWID
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw StoreError.query }
        defer { sqlite3_finalize(statement) }
        bindPage(statement)
        if let conversationID {
            sqlite3_bind_text(statement, beforeRowID == nil ? 3 : 4, conversationID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        func string(_ column: Int32) -> String? {
            guard let ptr = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: ptr)
        }
        var messages = [ChatMessage](), seen = Set<String>(), rows = Set<Int64>()
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw StoreError.query }
            let row = sqlite3_column_int64(statement, 0)
            rows.insert(row)
            let chatID = string(8) ?? "local-chat:\(sqlite3_column_int64(statement, 7))"
            let originalID = string(1) ?? "local-message:\(row)"
            let id = "\(chatID.utf8.count):\(chatID)\(originalID)"
            guard seen.insert(id).inserted else { continue }
            var body = string(2)
            let blobSize = Int(sqlite3_column_bytes(statement, 5))
            let richExists = blobSize > 0
            if body?.isEmpty != false, blobSize <= 2_097_152, let ptr = sqlite3_column_blob(statement, 5), richExists {
                body = BodyDecoder.text(from: Data(bytes: ptr, count: blobSize))
            }
            let attachments = attachmentsByMessage[row] ?? []
            var linkPreview: LinkPreviewMetadata?
            let payloadSize = Int(sqlite3_column_bytes(statement, 13))
            if attachments.contains(where: \.isLinkPayload), (1...262_144).contains(payloadSize),
               let ptr = sqlite3_column_blob(statement, 13) {
                linkPreview = LinkPreviewDecoder.decode(Data(bytes: ptr, count: payloadSize))
            }
            let hasAttachment = !attachments.isEmpty || sqlite3_column_int(statement, 6) != 0 || body?.contains("\u{fffc}") == true
            body = BodyDecoder.visibleText(body)
            let unavailable = body?.isEmpty != false && richExists && !hasAttachment
            let rendered = body?.isEmpty == false ? body! : (hasAttachment ? "Attachment" : "Message content unavailable")
            let title = [string(9), string(10), string(11), string(8)].compactMap { $0 }.first { !$0.isEmpty } ?? "Unknown conversation"
            messages.append(ChatMessage(id: id, conversationID: chatID, conversationTitle: title,
                sender: string(11) ?? "Participant", text: rendered, date: date(sqlite3_column_int64(statement, 3)),
                isFromMe: sqlite3_column_int(statement, 4) != 0, bodyUnavailable: unavailable, hasAttachment: hasAttachment,
                conversationService: string(12), conversationAddress: string(10), conversationDisplayName: string(9),
                attachments: attachments, linkPreview: linkPreview, sourceRowID: row))
        }
        let hasMore = rows.count > limit
        if hasMore, let extraRow = rows.min() { messages.removeAll { $0.sourceRowID == extraRow } }
        return Snapshot(messages: messages, sourceRows: min(rows.count, limit), limit: limit, hasMore: hasMore)
    }

    static var demo: Snapshot {
        let now = Date()
        let values: [(String, String, String, Bool, Int)] = [
            ("team", "Synapse project", "Welcome to your Messages inbox.", false, -3400),
            ("team", "Synapse project", "It is nice to have our conversations in one place. 👋", true, -3200),
            ("team", "Synapse project", "Choose a conversation on the left, or search your messages above.", false, -3000),
            ("weekend", "Weekend plans", "Coffee on Saturday afternoon? ☕️", false, -1700),
            ("weekend", "Weekend plans", "Sounds good! See you at two.", true, -1500),
            ("family", "Family", "Let’s have dinner together tonight. 🍲", false, -600),
            ("family", "Family", "I will be there around seven!", true, -400),
            ("team", "Synapse project", "This is a sample. Your conversations are read only after you select Connect Messages.", false, -10)
        ]
        return Snapshot(messages: values.enumerated().map { index, v in
            ChatMessage(id: "demo-\(index)", conversationID: v.0, conversationTitle: v.1, sender: v.1,
                text: v.2, date: now.addingTimeInterval(Double(v.4)), isFromMe: v.3, bodyUnavailable: false, hasAttachment: false)
        }, sourceRows: values.count, limit: 2000)
    }
}
