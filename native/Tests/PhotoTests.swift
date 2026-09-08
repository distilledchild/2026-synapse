import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PhotoTestContacts: ContactProviding {
    func authorization() -> ContactAccess { .denied }
    func requestAccess() async -> Bool { fatalError("No real Contacts in photo tests") }
    func lookup(_ handles: Set<String>) async throws -> [String: ContactIdentity] { [:] }
}

actor PhotoTestSender: MessageSending {
    var requests: [SendRequest] = []
    var continuation: CheckedContinuation<SendOutcome, Never>?
    func send(_ request: SendRequest) async -> SendOutcome {
        requests.append(request)
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ outcome: SendOutcome) { continuation?.resume(returning: outcome); continuation = nil }
}

@main struct PhotoTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            checks += 1; print("PASS: \(label)")
        }
        func waitFor(_ predicate: () -> Bool) async {
            for _ in 0..<500 {
                if predicate() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Photo state timeout")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-photo-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("사진 ' \" 🌍.png")
        func writeImage(_ url: URL, red: CGFloat = 0.4) throws {
            let context = CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: red, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            guard CGImageDestinationFinalize(destination) else { fatalError("Fixture image write failed") }
        }
        try writeImage(url)
        let photo = try PhotoFile.select(url)
        check(photo.isValid && photo.name == url.lastPathComponent, "selected photo preserves Unicode filename and validated metadata")
        let data = try PhotoFile.verifiedData(photo)
        check(PhotoFile.thumbnail(data)?.width == 48, "photo preview decodes the reviewed file")
        let chatID = "any;-;photo@example.invalid"
        let request = SendRequest(id: UUID(), chatID: chatID, text: "", service: "RCS", photo: photo)
        let decoded = try JSONDecoder().decode(SendRequest.self, from: JSONEncoder().encode(request))
        check(request.isValid && decoded == request, "photo-only request round trips through helper JSON")
        check(!SendRequest(id: UUID(), chatID: chatID, text: "caption", service: "RCS", photo: photo).isValid, "photo and text are not silently split into partial sends")
        let echo = NSAppleScript(source: "on deliverMessage(chatID, messageText, validationOnly, photoPath)\nreturn {chatID, messageText, validationOnly, photoPath, POSIX file photoPath as alias}\nend deliverMessage")!
        var error: NSDictionary?
        let reply = echo.executeAppleEvent(MessageScript.event(for: request, validationOnly: true), error: &error)
        check(error == nil && reply.atIndex(4)?.stringValue == photo.path && reply.atIndex(5) != nil, "photo path reaches AppleScript unchanged and resolves to a file alias without sending")
        check(reply.atIndex(3)?.booleanValue == true, "photo target probe preserves validation-only mode")
        let bad = root.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: bad)
        check((try? PhotoFile.select(bad)) == nil, "renamed non-image file is rejected")
        check((try? PhotoFile.select(root)) == nil, "directories cannot be attached")
        let huge = root.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let hugeHandle = try FileHandle(forWritingTo: huge)
        try hugeHandle.truncate(atOffset: UInt64(PhotoFile.maximumBytes + 1)); try hugeHandle.close()
        check((try? PhotoFile.select(huge)) == nil, "oversized photo is rejected before decoding")
        try writeImage(url, red: 0.9)
        check((try? PhotoFile.verifiedData(photo)) == nil, "changed photo cannot replace the reviewed content")
        let current = try PhotoFile.select(url)

        let sender = PhotoTestSender()
        let sample = Snapshot(messages: [chatID, "any;-;other"].map {
            ChatMessage(id: $0, conversationID: $0, conversationTitle: "Test", sender: "Test", text: "Fixture",
                date: Date(), isFromMe: false, bodyUnavailable: false, hasAttachment: false, conversationService: "RCS")
        }, sourceRows: 2, limit: 2000)
        let model = InboxModel(messageNameProvider: NoMessageNames(), sender: sender, startTimer: false, loader: { _ in sample }, contacts: PhotoTestContacts())
        model.selectPhoto(url, for: "team")
        await waitFor { !model.isBusy }
        model.setDraft("Text stays", for: "team")
        model.send(to: "team")
        model.search = "hide everything"
        await waitFor { !model.isBusy }
        let demoCalls = await sender.requests.count
        check(demoCalls == 0 && model.snapshot.messages.last?.hasAttachment == true, "sample photo remains local even if search changes during send")
        check(model.photoDrafts["team"] == nil && model.draft(for: "team") == "Text stays", "photo success clears the photo and preserves typed text")
        model.disconnect()
        check(model.demoImagePaths.isEmpty, "disconnect clears sample image access")
        model.connect(path: "/synthetic/import.db")
        await waitFor { !model.isLoading }
        model.selectPhoto(url, for: chatID)
        check(!model.canSelectPhoto(in: chatID) && model.photoDrafts.isEmpty, "imported DB cannot select or send photos")
        model.connect()
        await waitFor { !model.isLoading }
        model.selectPhoto(url, for: chatID)
        await waitFor { !model.isBusy }
        check(model.canSend(to: chatID) && model.photoDrafts[chatID]?.digest == current.digest, "photo-only draft enables sending to an existing RCS chat")
        model.setDraft("Keep this text", for: chatID)
        model.selectedID = "any;-;other"
        check(model.photoDrafts["any;-;other"] == nil, "photo selection remains scoped to its conversation")
        model.send(to: chatID)
        model.send(to: chatID)
        model.removePhoto(for: chatID)
        model.disconnect()
        await waitFor { model.isSending }
        for _ in 0..<500 {
            if await sender.requests.count == 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let sent = await sender.requests
        check(sent.count == 1 && sent[0].chatID == chatID && sent[0].photo?.digest == current.digest && sent[0].text.isEmpty,
            "duplicate clicks send one photo to the captured conversation without sending draft text")
        check(model.photoDrafts[chatID] != nil && model.isLiveConnection, "in-flight photo blocks removal and disconnect")
        await sender.finish(.unknown)
        await waitFor { !model.isSending }
        check(model.photoDrafts[chatID] != nil && !model.canSend(to: chatID) && !model.canSelectPhoto(in: chatID), "unknown photo result preserves selection and blocks retries")
        model.acknowledgeUnknown(for: chatID)
        model.send(to: chatID)
        for _ in 0..<500 {
            if await sender.requests.count == 2 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await sender.finish(.accepted)
        await waitFor { !model.isBusy && !model.isLoading }
        check(model.photoDrafts[chatID] == nil && model.draft(for: chatID) == "Keep this text", "successful live photo request clears only the photo")
        model.selectPhoto(url, for: chatID)
        await waitFor { !model.isBusy }
        try writeImage(url, red: 0.1)
        let beforeChanged = await sender.requests.count
        model.send(to: chatID)
        await waitFor { !model.isBusy }
        let afterChanged = await sender.requests.count
        check(beforeChanged == afterChanged && model.sendResults[chatID] == .attachmentUnavailable, "changed photo is stopped before invoking the sender")
        model.selectPhoto(bad, for: chatID)
        await waitFor { !model.isBusy }
        check(model.photoDrafts[chatID] == nil && model.photoErrors[chatID] != nil, "invalid replacement does not leave a stale photo selected")
        model.disconnect()
        check(model.photoDrafts.isEmpty && model.photoErrors.isEmpty, "disconnect clears photo drafts and errors")

        // Production helper validation rejects the changed file before it contacts Messages.
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let outcome = await AppleMessageSender(executableURL: helper).send(request)
        check(outcome == .attachmentUnavailable, "production helper revalidates file content before any Apple event")
        print("SUCCESS: \(checks) photo sending checks; no real messages sent")
    }
}
