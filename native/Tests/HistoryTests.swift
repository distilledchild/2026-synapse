import Foundation
import SQLite3

struct HistoryContacts: ContactProviding {
    func authorization() -> ContactAccess { .denied }
    func requestAccess() async -> Bool { false }
    func lookup(_ handles: Set<String>) async throws -> [String: ContactIdentity] { [:] }
}

final class HistoryFixture: @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var calls = 0
    private var shouldFail = false
    private var delay: TimeInterval = 0
    init(path: String) { self.path = path }
    func configure(fail: Bool = false, delay: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        shouldFail = fail; self.delay = delay
    }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func load(_ id: String, before: Int64?) throws -> Snapshot {
        lock.lock(); calls += 1; let fail = shouldFail, delay = delay; lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if fail { throw StoreError.query }
        return try MessageStore.load(path: path, limit: 4, conversationID: id, beforeRowID: before)
    }
}

@main
struct HistoryTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            checks += 1; print("PASS: \(label)")
        }
        func waitFor(_ predicate: () -> Bool) async {
            for _ in 0..<300 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Timed out waiting for history")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.db").path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { fatalError("Fixture open failed") }
        defer { sqlite3_close(db) }
        func sql(_ value: String) {
            guard sqlite3_exec(db, value, nil, nil, nil) == SQLITE_OK else { fatalError("Fixture query failed") }
        }
        let id = "any;-;alpha@example.invalid", other = "any;-;beta@example.invalid"
        sql("""
        CREATE TABLE message(guid TEXT,text TEXT,date INTEGER,is_from_me INTEGER);
        CREATE TABLE chat(guid TEXT,chat_identifier TEXT,service_name TEXT);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE attachment(filename TEXT,mime_type TEXT,transfer_name TEXT);
        CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        INSERT INTO chat VALUES('\(id)','alpha@example.invalid','iMessage'),('\(other)','beta@example.invalid','iMessage');
        WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10)
        INSERT INTO message(rowid,guid,text,date,is_from_me) SELECT x,'a-'||x,'old message '||x,800000000,0 FROM n;
        INSERT INTO chat_message_join SELECT 1,rowid FROM message;
        WITH RECURSIVE n(x) AS (VALUES(100) UNION ALL SELECT x+1 FROM n WHERE x<2200)
        INSERT INTO message(rowid,guid,text,date,is_from_me) SELECT x,'b-'||x,'other chat',800000001,0 FROM n;
        INSERT INTO chat_message_join SELECT 2,rowid FROM message WHERE rowid>=100;
        INSERT INTO message(rowid,guid,text,date,is_from_me) VALUES(3001,'a-recent-1','needle',800000002,0),(3002,'a-recent-2','안녕하세요 🌍',800000003,1);
        INSERT INTO chat_message_join VALUES(1,3001),(1,3001),(1,3002),(2,3001);
        INSERT INTO attachment VALUES('/synthetic/old.png','image/png','old.png'),('/synthetic/recent.png','image/png','recent.png');
        INSERT INTO message_attachment_join VALUES(8,1),(3001,2);
        """)
        let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let recent = try MessageStore.load(path: path)
        check(recent.messages.filter { $0.conversationID == id }.count == 2 && recent.hasMore, "global recent window can contain only two messages from a much older chat")
        let first = try MessageStore.load(path: path, limit: 4, conversationID: id)
        check(first.messages.map(\.sourceRowID) == [9, 10, 3001, 3002] && first.hasMore, "conversation page loads older rows outside the global window")
        check(first.messages.allSatisfy { $0.conversationID == id } && first.messages.count == 4, "shared and duplicate joins cannot leak another conversation into a page")
        check(first.messages.first { $0.sourceRowID == 3001 }?.attachments.first?.name == "recent.png", "attachments follow the scoped conversation page")
        let second = try MessageStore.load(path: path, limit: 4, conversationID: id, beforeRowID: first.oldestRowID)
        check(second.messages.map(\.sourceRowID) == [5, 6, 7, 8] && second.hasMore, "exclusive row cursor has no gaps or overlap even with equal dates")
        check(second.messages.last?.attachments.first?.name == "old.png", "older page retains its photo metadata")
        sql("INSERT INTO message(rowid,guid,text,date,is_from_me) VALUES(3003,'a-new','new arrival',800000004,0); INSERT INTO chat_message_join VALUES(1,3003);")
        let last = try MessageStore.load(path: path, limit: 4, conversationID: id, beforeRowID: second.oldestRowID)
        check(last.messages.map(\.sourceRowID) == [1, 2, 3, 4] && !last.hasMore, "new arrivals do not shift an older cursor and the final page reports completion")
        let empty = try MessageStore.load(path: path, limit: 4, conversationID: id, beforeRowID: 1)
        check(empty.messages.isEmpty && !empty.hasMore, "past the earliest row returns an empty final page")
        let malicious = try MessageStore.load(path: path, conversationID: "' OR 1=1 --")
        check(malicious.messages.isEmpty, "conversation IDs are SQL parameters")
        let stable = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try MessageStore.load(path: path, limit: 4, conversationID: id, beforeRowID: 9)
        check(stable == (try? Data(contentsOf: URL(fileURLWithPath: path))) && stable != beforeBytes, "history read leaves the fixture unchanged after the intentional incoming message")

        let fixture = HistoryFixture(path: path)
        let model = InboxModel(messageNameProvider: NoMessageNames(), startTimer: false,
            loader: { _ in try MessageStore.load(path: path, limit: 20) }, contacts: HistoryContacts(),
            historyLoader: { _, id, before in try fixture.load(id, before: before) })
        model.ensureHistory(for: id)
        check(fixture.callCount == 0, "sample mode never reads personal history")
        model.connect()
        await waitFor { !model.isLoading }
        model.selectedID = id
        model.setDraft("Keep my draft", for: id)
        model.ensureHistory(for: id); model.ensureHistory(for: id)
        await waitFor { model.histories[id]?.isLoading == false }
        check(fixture.callCount == 1 && model.selected?.messages.count == 4, "opening a conversation loads one page without duplicate requests")
        model.search = "needle"
        check(model.selected?.messages.count == 4 && model.selected?.messages.contains { $0.text == "안녕하세요 🌍" } == true, "search selects the conversation while preserving surrounding messages and original Unicode")
        model.loadOlderHistory(for: id)
        await waitFor { model.histories[id]?.isLoading == false }
        check(model.selected?.messages.count == 8 && model.draft(for: id) == "Keep my draft" && model.canSend(to: id), "older messages merge without duplicates or changing the draft and recipient")
        model.refresh()
        await waitFor { !model.isLoading }
        check(model.selected?.messages.count == 8, "automatic recent refresh preserves older loaded messages")
        fixture.configure(fail: true)
        model.loadOlderHistory(for: id)
        await waitFor { model.histories[id]?.isLoading == false }
        check(model.histories[id]?.error != nil && model.selected?.messages.count == 8, "history failure leaves loaded content and cursor available for retry")
        fixture.configure()
        model.loadOlderHistory(for: id)
        await waitFor { model.histories[id]?.isLoading == false }
        model.loadOlderHistory(for: id)
        await waitFor { model.histories[id]?.isLoading == false }
        check(model.selected?.messages.count == 13 && model.histories[id]?.hasMore == false, "retry continues at the same cursor and loads the complete conversation")
        let totalCalls = fixture.callCount
        model.loadOlderHistory(for: id)
        check(fixture.callCount == totalCalls, "complete history does not keep issuing empty reads")
        sql("DELETE FROM chat_message_join WHERE message_id=3003; DELETE FROM message WHERE rowid=3003;")
        model.refresh()
        await waitFor { !model.isLoading }
        check(model.selected?.messages.count == 12, "deleting a recent message is reflected without restoring it from history")
        fixture.configure(delay: 0.08)
        model.loadOlderHistory(for: other)
        model.disconnect()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(model.histories.isEmpty && model.isDemo, "late history cannot reappear after disconnect")
        model.connect(path: path)
        await waitFor { !model.isLoading }
        model.ensureHistory(for: id)
        await waitFor { model.histories[id]?.isLoading == false }
        check(model.histories[id]?.hasLoaded == true && !model.canSend(to: id), "imported databases support local history while remaining read-only")
        print("SUCCESS: \(checks) history checks; no personal messages read or sent")
    }
}
