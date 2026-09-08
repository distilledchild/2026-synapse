import Foundation

final class FixtureMessageNames: MessageNamesProviding, @unchecked Sendable {
    var names: [String: String] = [:]
    var delay: UInt64 = 0
    var failure: MessageNameError?
    private(set) var lookups = 0
    func lookup(_ chatIDs: Set<String>) async throws -> [String: String] {
        lookups += 1
        let captured = names
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        return captured.filter { chatIDs.contains($0.key) }
    }
}
struct UnavailableContacts: ContactProviding {
    func authorization() -> ContactAccess { .denied }
    func requestAccess() async -> Bool { fatalError("Unexpected Contacts request") }
    func lookup(_ handles: Set<String>) async throws -> [String: ContactIdentity] { fatalError("Unexpected Contacts read") }
}

@main
struct MessageNameTests {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            count += 1; print("PASS: \(label)")
        }
        func waitFor(_ predicate: () -> Bool) async {
            for _ in 0..<300 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Timed out waiting for message names")
        }
        let address = "+15555550123", id = "any;-;+15555550123"
        let request = MessageNameRequest(chatIDs: [id])
        check(request.isValid, "direct RCS/any chat can resolve a display name without changing its route")
        check(!MessageNameRequest(chatIDs: ["any;+;group"]).isValid, "group is not renamed to an individual participant")
        check(!MessageNameRequest(chatIDs: [id, id]).isValid && !MessageNameRequest(chatIDs: []).isValid, "duplicate and empty batches are rejected")
        check(!MessageNameRequest(chatIDs: (0...24).map { "any;-;\($0)" }).isValid, "batch size is bounded")
        check(!MessageNameRequest(chatIDs: ["any;-;x\n"]).isValid, "control characters in a chat ID are rejected")
        check(MessageNameScript.matchingName(chatID: id, participants: [(address, "Jamie 캘리포니아")]) == "Jamie 캘리포니아", "Messages preferred Unicode name is preserved exactly")
        check(MessageNameScript.matchingName(chatID: id, participants: [("+1 (555) 555-0123", "Jamie")]) == "Jamie", "formatting-only phone differences match")
        check(MessageNameScript.matchingName(chatID: id, participants: [("+825555550123", "Wrong person")]) == nil, "same suffix in another country never matches")
        check(MessageNameScript.matchingName(chatID: id, participants: [("+15555550199", "Wrong person")]) == nil, "a different participant cannot supply the title")
        check(MessageNameScript.matchingName(chatID: id, participants: [(address, address)]) == nil, "raw handle does not override Contacts fallback")
        check(MessageNameScript.matchingName(chatID: id, participants: [(address, "Jamie"), (address, "Jamie")]) == "Jamie", "duplicate identical participant labels still resolve")
        check(MessageNameScript.matchingName(chatID: id, participants: [(address, "Jamie"), (address, "Someone else")]) == nil, "ambiguous participants are not guessed")
        var error: NSDictionary?
        check(NSAppleScript(source: MessageNameScript.source)?.compileAndReturnError(&error) == true, "read-only script compiles against the installed Messages dictionary")
        let event = MessageNameScript.event(for: request)
        check(event.paramDescriptor(forKeyword: 0x2d2d2d2d)?.atIndex(1)?.atIndex(1)?.stringValue == id, "chat IDs use event descriptors rather than script interpolation")
        func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let result = NSAppleEventDescriptor.list()
            for (i, value) in values.enumerated() { result.insert(value, at: i + 1) }
            return result
        }
        let descriptor = list([list([NSAppleEventDescriptor(string: id), list([
            list([NSAppleEventDescriptor(string: address), NSAppleEventDescriptor(string: "Jamie 캘리포니아")])])])])
        check(MessageNameScript.response(from: descriptor, request: request).names[id] == "Jamie 캘리포니아", "Apple event result decoding retains Korean characters")
        check(MessageNameScript.response(from: NSAppleEventDescriptor(string: "permissionDenied"), request: request).error == .permissionDenied, "automation permission failure is explicit")

        let message = ChatMessage(id: "fixture", conversationID: id, conversationTitle: address,
            sender: address, text: "Fixture", date: Date(), isFromMe: false, bodyUnavailable: false,
            hasAttachment: false, conversationService: "RCS", conversationAddress: address)
        let snapshot = Snapshot(messages: [message], sourceRows: 1, limit: 2000)
        let contacts = [address: ContactIdentity(name: "Jamie California / Jamie 캘리포니아")]
        check(NamePresentation.title(for: message, names: contacts, messageNames: [id: "Jamie 캘리포니아"]) == "Jamie 캘리포니아", "Messages chosen label takes priority over multiple Contacts labels")
        var business = message; business.conversationDisplayName = "Fixture business"
        check(NamePresentation.title(for: business, names: contacts, messageNames: [id: "Jamie"]) == "Fixture business", "explicit business display names are preserved")

        let provider = FixtureMessageNames(); provider.names = [id: "Jamie 캘리포니아"]
        let model = InboxModel(messageNameProvider: provider, startTimer: false, loader: { _ in snapshot }, contacts: UnavailableContacts())
        model.refreshMessageNames()
        check(provider.lookups == 0, "sample mode does not access Messages names")
        model.connect()
        await waitFor { !model.isLoading && !model.isLoadingMessageNames }
        check(model.conversations.first?.title == "Jamie 캘리포니아" && model.senderName(address) == "Jamie 캘리포니아", "real connection resolves titles and sender labels independently of Contacts permission")
        model.setDraft("Preserve this draft", for: id)
        model.search = "캘리포니아"
        check(model.selected?.id == id && model.canSend(to: id), "name search keeps the exact original send target")
        model.search = "555550123"
        check(model.selected?.id == id, "the original number remains searchable")
        model.refresh()
        await waitFor { !model.isLoading }
        check(provider.lookups == 1, "five-second message refreshes reuse name cache")
        provider.names = [id: "Jamie Updated"]
        model.refreshMessageNames(invalidate: true)
        await waitFor { !model.isLoadingMessageNames }
        check(model.conversations.first?.title == "Jamie Updated" && model.draft(for: id) == "Preserve this draft", "name refresh updates UI without clearing draft")
        provider.failure = .permissionDenied
        model.refreshMessageNames(invalidate: true)
        await waitFor { !model.isLoadingMessageNames }
        check(model.messageNames.isEmpty && model.messageNamesError == .permissionDenied, "revoked automation clears cached Messages names and reports failure")
        provider.failure = nil; provider.delay = 80_000_000
        model.refreshMessageNames(invalidate: true)
        await Task.yield(); model.disconnect()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(model.messageNames.isEmpty && model.isDemo, "late name lookup cannot repopulate a disconnected model")
        let previous = provider.lookups
        model.connect(path: "/synthetic/import.db")
        await waitFor { !model.isLoading }
        model.refreshMessageNames(invalidate: true)
        check(provider.lookups == previous && model.messageNames.isEmpty, "imported databases never read personal Messages names")

        // Invalid requests are checked using the production executable; never send
        // valid real IDs from the automated test suite.
        for data in [Data("{}".utf8), try JSONEncoder().encode(MessageNameRequest(chatIDs: ["any;+;fixture"]))] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output
            try process.run(); input.fileHandleForWriting.write(data); try input.fileHandleForWriting.close()
            let response = try JSONDecoder().decode(MessageNameResponse.self, from: output.fileHandleForReading.readToEnd()!)
            process.waitUntilExit()
            check(response.error == .invalidRequest, "invalid helper input is rejected before accessing Messages")
        }
        print("SUCCESS: \(count) Messages name checks; no real Messages names queried")
    }
}
