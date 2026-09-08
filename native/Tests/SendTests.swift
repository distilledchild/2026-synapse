import Foundation

struct NoContacts: ContactProviding {
    func authorization() -> ContactAccess { .denied }
    func requestAccess() async -> Bool { fatalError("Sending tests must not request Contacts access") }
    func lookup(_ handles: Set<String>) async throws -> [String: ContactIdentity] { fatalError("Sending tests must not read Contacts") }
}

actor ControlledSender: MessageSending {
    private(set) var requests: [SendRequest] = []
    private var continuation: CheckedContinuation<SendOutcome, Never>?
    func send(_ request: SendRequest) async -> SendOutcome {
        requests.append(request)
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ outcome: SendOutcome) { continuation?.resume(returning: outcome); continuation = nil }
}

@main
struct SendTests {
    @MainActor
    static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            checks += 1
            print("PASS: \(label)")
        }
        func waitFor(_ predicate: () -> Bool) async {
            for _ in 0..<300 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Timed out waiting for test state")
        }
        let first = "any;-;synthetic@example.invalid", second = "any;+;synthetic-group"
        check(SendRequest.isSupportedChat("iMessage;-;legacy") && SendRequest.isSupportedChat("iMessage;+;legacy"), "legacy direct and group iMessage GUIDs")
        check(SendRequest.isSupportedChat(first, service: "iMessage") && SendRequest.isSupportedChat(second, service: "iMessage"), "modern any GUIDs use service_name for direct and group iMessage")
        check(!SendRequest.isSupportedChat(first), "any GUID without service is not guessed")
        check(SendRequest.isSupportedChat(first, service: "SMS") && SendRequest.isSupportedChat(second, service: "RCS"), "any SMS and RCS chats support sending")
        check(!SendRequest.isSupportedChat("iMessage;-;conflict", service: "SMS"), "explicit conflicting service blocks legacy GUID")
        check(SendRequest.isSupportedChat("SMS;-;legacy") && SendRequest.isSupportedChat("RCS;+;legacy"), "legacy SMS and RCS GUIDs supported")
        check(!SendRequest.isSupportedChat(first, service: "unsupported"), "unknown any service rejected")
        for id in ["", "local-chat:0", "c1", "unsupported;-;test", "any;-;", "iMessage;;x", "iMessage;-;", "iMessage;-;x\n"] {
            check(!SendRequest.isSupportedChat(id), "unsupported or malformed target blocked")
        }
        check(!SendRequest.isValidText(" \n\t"), "whitespace blocked")
        check(!SendRequest.isValidText("x\0y"), "NUL blocked")
        check(SendRequest.isValidText(String(repeating: "a", count: 16_384)), "body size boundary accepted")
        check(!SendRequest.isValidText(String(repeating: "가", count: 5_462)), "UTF-8 byte limit enforced")
        // Execute a harmless local handler, never the Messages handler. This verifies the actual
        // Apple event calling convention and exact Unicode/injection-like text round trip.
        let body = "  한글 👋 \"quote\" \\ slash\nend tell\ndo shell script \"false\"\r\ttail  "
        let request = SendRequest(id: UUID(), chatID: first, text: body, service: "iMessage")
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(SendRequest.self, from: encoded)
        check(decoded == request, "helper JSON exact text round trip")
        let echo = NSAppleScript(source: "on deliverMessage(chatID, messageText, validationOnly, photoPath)\nreturn {chatID, messageText, validationOnly, photoPath}\nend deliverMessage")!
        var scriptError: NSDictionary?
        let reply = echo.executeAppleEvent(MessageScript.event(for: request), error: &scriptError)
        check(scriptError == nil && reply.atIndex(1)?.stringValue == first && reply.atIndex(2)?.stringValue == body,
              "Apple event parameters preserve text without script interpolation")
        check(reply.atIndex(3)?.booleanValue == false, "normal request uses sending handler mode")
        let validationReply = echo.executeAppleEvent(MessageScript.event(for: request, validationOnly: true), error: &scriptError)
        check(scriptError == nil && validationReply.atIndex(3)?.booleanValue == true, "read-only target probe passes validation-only flag")
        let production = NSAppleScript(source: MessageScript.source)!
        check(production.compileAndReturnError(&scriptError), "production Messages script compiles without sending")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-sender-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func stub(_ name: String, _ body: String) throws -> URL {
            let url = temporary.appendingPathComponent(name)
            try ("#!/bin/sh\ncat >/dev/null\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let success = try stub("success", "printf '\"accepted\"'")
        let successOutcome = await AppleMessageSender(executableURL: success).send(request)
        check(successOutcome == .accepted, "process transport reads helper outcome")
        let malformed = try stub("malformed", "printf 'bad-response'")
        let malformedOutcome = await AppleMessageSender(executableURL: malformed).send(request)
        check(malformedOutcome == .unknown, "malformed helper response is unknown")
        let crash = try stub("crash", "exit 1")
        let crashOutcome = await AppleMessageSender(executableURL: crash).send(request)
        check(crashOutcome == .unknown, "helper crash is unknown")
        let slow = try stub("slow", "exec /bin/sleep 2")
        let slowOutcome = await AppleMessageSender(executableURL: slow, timeout: 0.1).send(request)
        check(slowOutcome == .unknown, "helper deadline is unknown without retry")
        let missingOutcome = await AppleMessageSender(executableURL: temporary.appendingPathComponent("missing")).send(request)
        check(missingOutcome == .unavailable, "missing helper fails before sending")
        let invalidOutcome = await AppleMessageSender(executableURL: success).send(SendRequest(id: UUID(), chatID: first, text: " "))
        check(invalidOutcome == .invalidRequest, "transport rejects invalid input")

        let fixtureIDs = [first, second, "any;-;sms", "any;-;rcs", "any;-;unknown"]
        let fixtureServices: [String?] = ["iMessage", "iMessage", "SMS", "RCS", nil]
        let sample = Snapshot(messages: fixtureIDs.enumerated().map { index, id in
            ChatMessage(id: "fixture-\(index)", conversationID: id, conversationTitle: "Test \(index)",
                sender: "Synthetic", text: "Fixture", date: Date(), isFromMe: false,
                bodyUnavailable: false, hasAttachment: false, conversationService: fixtureServices[index])
        }, sourceRows: fixtureIDs.count, limit: 2000)
        let sender = ControlledSender()
        let model = InboxModel(messageNameProvider: NoMessageNames(), sender: sender, startTimer: false, loader: { _ in sample }, contacts: NoContacts())
        model.setDraft(body, for: "team")
        model.send(to: "team")
        check(model.snapshot.messages.last?.text == body && model.draft(for: "team").isEmpty, "sample send appends exact text and clears draft")
        let demoRequests = await sender.requests
        check(demoRequests.isEmpty, "sample mode never invokes real sender")
        model.connect(path: "/synthetic/chat.db")
        await waitFor { !model.isLoading }
        model.setDraft("Imported", for: first)
        model.send(to: first)
        check(!model.canCompose(in: first) && !model.isSending, "imported DB cannot send even with valid live GUID")
        model.connect()
        await waitFor { !model.isLoading }
        model.setDraft(body, for: first)
        model.setDraft("Other draft", for: second)
        check(model.canSend(to: first), "live iMessage composer enabled")
        check(model.canSend(to: second), "modern group iMessage composer enabled")
        check(model.canCompose(in: "any;-;sms") && model.canCompose(in: "any;-;rcs") && !model.canCompose(in: "any;-;unknown"), "live SMS and RCS enable composer while unknown service stays read-only")
        model.send(to: first)
        model.send(to: first)
        model.selectedID = second
        model.send(to: second)
        model.disconnect()
        model.connect(path: "/another.db")
        check(model.isSending && model.isLiveConnection, "in-flight send blocks reconnect, disconnect and other sends")
        for _ in 0..<300 {
            if await sender.requests.count == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let requests = await sender.requests
        check(requests.count == 1 && requests[0].chatID == first && requests[0].text == body, "duplicate clicks send once to captured conversation")
        check(requests[0].service == "iMessage" && requests[0].isValid, "modern GUID and service reach helper contract unchanged")
        await sender.finish(.accepted)
        await waitFor { !model.isSending && !model.isLoading }
        check(model.draft(for: first).isEmpty && model.draft(for: second) == "Other draft", "success clears only the sent conversation draft")
        check(model.sendResults[first] == .accepted && model.sendResults[second] == nil, "result remains scoped after switching conversation")

        var expectedRequests = 1
        for outcome: SendOutcome in [.permissionDenied, .targetUnavailable, .unavailable, .unknown] {
            model.setDraft("Keep draft", for: first)
            model.send(to: first)
            expectedRequests += 1
            for _ in 0..<300 {
                if await sender.requests.count == expectedRequests { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            await sender.finish(outcome)
            await waitFor { !model.isSending }
            check(model.draft(for: first) == "Keep draft" && model.sendResults[first] == outcome, "\(outcome) retains draft and exposes state")
        }
        check(!model.canSend(to: first), "unknown outcome blocks accidental retry")
        model.setDraft("Changed body", for: first)
        model.send(to: first)
        check(!model.isSending, "editing cannot bypass unknown-outcome guard")
        model.acknowledgeUnknown(for: first)
        check(model.canSend(to: first), "explicit result acknowledgement unlocks manual send")
        let beforeDisconnect = await sender.requests.count
        model.disconnect()
        check(model.drafts.isEmpty && model.sendResults.isEmpty && model.isDemo, "disconnect clears drafts and results")
        let afterDisconnect = await sender.requests.count
        check(afterDisconnect == beforeDisconnect, "disconnect never retries")
        model.connect()
        await waitFor { !model.isLoading }
        var serviceRequestCount = afterDisconnect
        for (id, service) in [("any;-;sms", "SMS"), ("any;-;rcs", "RCS")] {
            model.setDraft("Service fixture", for: id)
            model.send(to: id)
            serviceRequestCount += 1
            for _ in 0..<300 {
                if await sender.requests.count == serviceRequestCount { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let lastRequest = await sender.requests.last
            check(lastRequest?.chatID == id && lastRequest?.service == service && lastRequest?.isValid == true, "\(service) exact conversation reaches valid helper request")
            await sender.finish(.accepted)
            await waitFor { !model.isSending && !model.isLoading }
            check(model.draft(for: id).isEmpty && model.sendResults[id] == .accepted, "\(service) accepted request clears matching draft")
        }
        print("SUCCESS: \(checks) sending checks; no real messages sent")
    }
}
