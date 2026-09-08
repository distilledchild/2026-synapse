import Foundation
import SQLite3

@main
struct Tests {
    static func main() throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            checks += 1
            print("PASS: \(label)")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("synapse-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("메시지 #?.db").path
        var writer: OpaquePointer?
        check(sqlite3_open(path, &writer) == SQLITE_OK, "fixture creation")
        defer { sqlite3_close(writer) }
        func sql(_ text: String) throws {
            guard sqlite3_exec(writer, text, nil, nil, nil) == SQLITE_OK else { throw StoreError.query }
        }
        try sql("""
        CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER,attributedBody BLOB,
        cache_has_attachments INTEGER,handle_id INTEGER,associated_message_type INTEGER,item_type INTEGER);
        CREATE TABLE chat(guid TEXT,display_name TEXT,chat_identifier TEXT);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE handle(id TEXT);
        INSERT INTO handle VALUES('테스트 상대');
        INSERT INTO chat VALUES('c1','합성 대화','chat-1'),('c2','','chat-2');
        INSERT INTO message VALUES('m1','hello',800000000000000000,0,NULL,0,1,0,0);
        INSERT INTO message VALUES('m2',NULL,800000001000000000,1,NULL,1,1,0,0);
        INSERT INTO chat_message_join VALUES(1,1),(1,1),(2,1),(1,2);
        """)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let snapshot = try MessageStore.load(path: path)
        check(snapshot.sourceRows == 2 && snapshot.messages.count == 3, "duplicate joins deduplicated, multiple conversations retained")
        check(snapshot.messages.first?.sender == "테스트 상대", "sender mapping")
        check(snapshot.messages.last?.text == "Attachment", "attachment-only placeholder")
        check(snapshot.messages.last?.isFromMe == true, "outgoing direction")
        check(snapshot.messages.allSatisfy { $0.conversationService == nil }, "legacy schema without service_name remains readable")
        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        check(before == after, "source DB bytes unchanged")
        let page = try MessageStore.load(path: path, limit: 1)
        check(page.sourceRows == 1 && page.messages.first?.id.hasSuffix("m2") == true, "latest source-row pagination")
        let missing = root.appendingPathComponent("missing.db").path
        do { _ = try MessageStore.load(path: missing); fatalError("created missing DB") } catch { checks += 1 }
        check(!FileManager.default.fileExists(atPath: missing), "missing DB not created")
        check(MessageStore.date(800000000000000000) == MessageStore.date(800000000), "nanosecond and legacy second dates")
        check(MessageStore.date(0) == nil, "unknown date")
        check(MessageStore.date(Int64.min) != nil, "extreme timestamp does not overflow")
        for text in ["안녕하세요 Hello 🌍", "", String(repeating: "가🌍", count: 500), String(repeating: "X", count: 70000)] {
            let encoded = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
            check(BodyDecoder.text(from: encoded) == text, "native typedstream UTF-8 length \(text.utf8.count)")
        }
        let mutable = NSMutableAttributedString(string: "mutable 메시지")
        let mutableData = NSArchiver.archivedData(withRootObject: mutable)
        check(BodyDecoder.text(from: mutableData) == mutable.string, "mutable attributed string")
        let encoded = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "본문 해독 테스트"))
        for size in 0..<encoded.count {
            _ = BodyDecoder.text(from: encoded.prefix(size))
        }
        check(BodyDecoder.text(from: Data([0,1,2])) == nil, "unknown encoding rejected")
        check(BodyDecoder.text(from: Data([4,11]) + Data("streamtyped".utf8) + Data(repeating: 0, count: 7)) == nil, "short valid header bounds")
        let hex = encoded.map { String(format: "%02x", $0) }.joined()
        try sql("INSERT INTO message VALUES('m3',NULL,800000002000000000,0,X'\(hex)',0,1,0,0); INSERT INTO chat_message_join VALUES(1,3);")
        let decoded = try MessageStore.load(path: path)
        check(decoded.messages.last?.text == "본문 해독 테스트" && decoded.unavailableCount == 0, "attributed body integrated with DB reader")
        try sql("INSERT INTO message VALUES('tapback','reaction',800000003000000000,0,NULL,0,1,2000,0);")
        let reactions = try MessageStore.load(path: path)
        check(reactions.sourceRows == 3, "reaction events excluded")
        let oldCount = try MessageStore.load(path: path).sourceRows
        try sql("PRAGMA journal_mode=WAL;")
        try sql("INSERT INTO message VALUES('wal','new row',800000004000000000,0,NULL,0,1,0,0);")
        let wal = try MessageStore.load(path: path)
        check(wal.sourceRows == oldCount + 1, "live WAL reads committed new messages")
        try sql("UPDATE message SET text='edited' WHERE guid='wal';")
        let edited = try MessageStore.load(path: path)
        check(edited.messages.last?.text == "edited", "refresh reflects edits in loaded window")
        try sql("DELETE FROM message WHERE guid='wal';")
        let deleted = try MessageStore.load(path: path)
        check(deleted.sourceRows == oldCount, "refresh reflects deletion in loaded window")
        try sql("INSERT INTO message VALUES('unknown',NULL,800000005000000000,0,X'000102',0,1,0,0);")
        let unknown = try MessageStore.load(path: path)
        check(unknown.unavailableCount == 1, "unsupported body visible to user")
        let emptyPath = root.appendingPathComponent("empty.db").path
        var empty: OpaquePointer?; sqlite3_open(emptyPath, &empty); sqlite3_close(empty)
        do { _ = try MessageStore.load(path: emptyPath); fatalError("accepted unsupported schema") } catch StoreError.schema { checks += 1 }
        // Also verify bounded extraction never traps on arbitrary binary input.
        try sql("ALTER TABLE chat ADD COLUMN service_name TEXT;")
        try sql("UPDATE chat SET guid='any;-;synthetic@example.invalid',service_name='iMessage' WHERE ROWID=1;")
        try sql("UPDATE chat SET guid='any;-;synthetic-sms',service_name='SMS' WHERE ROWID=2;")
        let modern = try MessageStore.load(path: path)
        check(modern.messages.first { $0.conversationID == "any;-;synthetic@example.invalid" }?.conversationService == "iMessage", "modern any GUID preserves iMessage service metadata")
        check(modern.messages.first { $0.conversationID == "any;-;synthetic-sms" }?.conversationService == "SMS", "modern any GUID preserves SMS service metadata")
        try sql("""
        CREATE TABLE attachment(filename TEXT,mime_type TEXT,transfer_name TEXT);
        CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        INSERT INTO attachment VALUES('~/Library/Messages/Attachments/test/photo.heic','image/heic','photo.heic'),
            (NULL,'image/png','pending.png'),('/somewhere/report.pdf','application/pdf','report.pdf');
        INSERT INTO message_attachment_join VALUES(1,1),(1,1),(1,2),(2,3);
        """)
        let withAttachments = try MessageStore.load(path: path)
        let attached = withAttachments.messages.filter { $0.id.hasSuffix("m1") }
        check(attached.count == 2 && attached.allSatisfy { $0.attachments.count == 2 }, "multiple image attachments and shared conversations preserve order without duplicate joins")
        check(attached.allSatisfy { $0.hasAttachment && $0.text == "hello" }, "attachment join detects images even without cached flag and preserves caption")
        check(attached.first?.attachments.first?.isImage == true && attached.first?.attachments.last?.filename == nil, "HEIC and pending image metadata retained")
        check(withAttachments.messages.first { $0.id.hasSuffix("m2") }?.attachments.first?.isImage == false, "non-image file remains a named attachment")
        let attachmentPage = try MessageStore.load(path: path, limit: 1)
        check(attachmentPage.messages.allSatisfy { $0.attachments.isEmpty }, "attachments are scoped to loaded message page")
        let objectBody = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "\u{fffc}"))
        let objectHex = objectBody.map { String(format: "%02x", $0) }.joined()
        try sql("UPDATE message SET attributedBody=X'\(objectHex)' WHERE guid='m2';")
        let imageOnly = try MessageStore.load(path: path)
        check(imageOnly.messages.first { $0.id.hasSuffix("m2") }?.bodyUnavailable == false, "attachment-only object marker is not labeled an unsupported body")
        for marker in ["\u{fffe}", "\u{ffff}"] {
            let markerHex = NSArchiver.archivedData(withRootObject: NSAttributedString(string: marker)).map { String(format: "%02x", $0) }.joined()
            try sql("UPDATE message SET attributedBody=X'\(markerHex)' WHERE guid='m2';")
            let marked = try MessageStore.load(path: path).messages.first { $0.id.hasSuffix("m2") }!
            check(marked.text == "Attachment" && !marked.bodyUnavailable && marked.attachments.count == 1, "rich attachment marker is replaced with readable sidebar text and preserves media")
        }
        check(BodyDecoder.visibleText("\u{fffe}사진 설명 🌍\u{ffff}") == "사진 설명 🌍", "transport marker removal preserves the actual caption and emoji")
        check(BodyDecoder.visibleText("정말? �") == "정말? �", "literal question marks and replacement characters are not silently deleted")
        let payloadURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/link-preview.plist")
        let linkData = try Data(contentsOf: payloadURL)
        let linkMetadata = LinkPreviewDecoder.decode(linkData)
        check(linkMetadata?.title == "Synthetic link preview" && linkMetadata?.imageIndex == 1, "binary archive UID graph resolves title and primary image without unarchiving objects")
        check(LinkPreviewDecoder.decode(Data([0, 1, 2])) == nil && LinkPreviewDecoder.decode(Data(repeating: 0, count: 262145)) == nil, "corrupt and oversized link metadata is ignored")
        let payloadHex = linkData.map { String(format: "%02x", $0) }.joined()
        try sql("ALTER TABLE message ADD COLUMN payload_data BLOB;")
        try sql("UPDATE message SET payload_data=X'\(payloadHex)' WHERE guid='m1';")
        try sql("UPDATE attachment SET filename='~/Library/Messages/Attachments/icon.pluginPayloadAttachment',mime_type=NULL,transfer_name='icon.pluginPayloadAttachment' WHERE rowid=1;")
        try sql("UPDATE attachment SET filename='~/Library/Messages/Attachments/photo.pluginPayloadAttachment',mime_type=NULL,transfer_name='photo.pluginPayloadAttachment' WHERE rowid=2;")
        let linked = try MessageStore.load(path: path).messages.first { $0.id.hasSuffix("m1") }!
        check(linked.visibleAttachments.count == 1 && linked.visibleAttachments.first?.id == 2, "primary link image replaces favicon and internal payload file list")
        check(linked.visibleAttachments.first?.isImage == true && linked.visibleAttachments.first?.displayName == "Link preview", "extensionless payload image uses a readable label")
        var invalidIndex = linked
        invalidIndex.linkPreview = LinkPreviewMetadata(title: nil, imageIndex: 99)
        check(invalidIndex.visibleAttachments.count == 2, "unknown thumbnail index preserves attachment fallback")
        for length in 0..<512 { _ = BodyDecoder.text(from: Data((0..<length).map { _ in UInt8.random(in: 0...255) })) }
        print("SUCCESS: \(checks) checks plus truncation and random-input decoder checks")
    }
}
