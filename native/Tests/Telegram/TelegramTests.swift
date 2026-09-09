import Foundation
import AppKit
import Vision

final class MemoryTelegramSecrets: TelegramSecretStoring {
    var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { values[account] }
    func write(_ data: Data, account: String) throws { values[account] = data }
}

@MainActor final class FixtureTelegramTransport: TelegramTransport {
    var onUpdate: ((TelegramObject) -> Void)?
    var requests: [TelegramObject] = []
    var handler: ((TelegramObject) async throws -> TelegramObject)?
    func start() throws { emitAuth("authorizationStateWaitTdlibParameters") }
    func request(_ object: TelegramObject) async throws -> TelegramObject {
        requests.append(object)
        if let handler { return try await handler(object) }
        return ["@type": "ok"]
    }
    func close() async { emitAuth("authorizationStateClosed") }
    func emitAuth(_ type: String) { onUpdate?(["@type": "updateAuthorizationState", "authorization_state": ["@type": type]]) }
    func emit(_ object: TelegramObject) { onUpdate?(object) }
}

@main struct TelegramTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        var count = 0
        func check(_ result: @autoclosure () -> Bool, _ label: String) {
            guard result() else { fatalError("FAIL: " + label) }
            count += 1; print("PASS: " + label)
        }
        func settle() async { try? await Task.sleep(nanoseconds: 70_000_000) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-telegram-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let secrets = MemoryTelegramSecrets(), storage = TelegramStorage(secrets: secrets, root: temp)
        let credentials = TelegramCredentials(apiID: 1, apiHash: String(repeating: "0", count: 32))
        check(credentials.isValid, "synthetic API configuration validates")
        check(!TelegramCredentials(apiID: 0, apiHash: credentials.apiHash).isValid, "zero API ID is rejected")
        check(!TelegramCredentials(apiID: 1, apiHash: "bad").isValid, "malformed hash is rejected")
        let missing = try storage.loadCredentials()
        check(missing == nil, "no bundled or fallback API credentials")
        try storage.saveCredentials(credentials)
        let saved = try storage.loadCredentials()
        check(saved == credentials, "credentials round-trip through injected secure store")
        let key = try storage.encryptionKey()
        let repeatedKey = try storage.encryptionKey()
        check(key.count == 32 && repeatedKey == key, "random database key is stable across connections")
        try storage.prepare()
        let permissions = try FileManager.default.attributesOfItem(atPath: temp.path)[.posixPermissions] as? Int
        check(permissions == 0o700, "private cache folder permits only its owner")
        let parameters = storage.parameters(credentials: credentials, key: key)
        check(parameters.string("database_encryption_key") == key.base64EncodedString(), "TDLib receives the database encryption key")
        check(!parameters.flag("use_test_dc") && !parameters.flag("use_secret_chats"), "production cloud chats are the initial supported scope")
        let credentialFiles = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        check(credentialFiles.allSatisfy { ["database", "files"].contains($0.lastPathComponent) }, "credentials are never written into cache files")
        check(TelegramFailure.from(["code": 400, "message": "PHONE_CODE_INVALID PRIVATE_FIXTURE"]) == .code, "authorization errors use allowlisted descriptions")
        check(!TelegramFailure.from(["code": 500, "message": "PRIVATE_FIXTURE"]).localizedDescription.contains("PRIVATE_FIXTURE"), "raw server response cannot leak into UI errors")
        check(TelegramFailure.from(["code": 429, "message": "PRIVATE_FIXTURE"]) == .rateLimited, "rate limits are surfaced without payloads")
        check(TelegramFailure.from(["code": 404]) == .notFound, "end-of-list response is distinct from a retryable failure")

        let qrFixture = "tg://login?token=" + String(repeating: "A", count: 43)
        let qrRotated = "tg://login?token=" + String(repeating: "B", count: 43)
        let qrImage = TelegramLoginQR.image(for: qrFixture)!
        let barcode = VNDetectBarcodesRequest()
        barcode.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: qrImage).perform([barcode])
        check(barcode.results?.first?.payloadStringValue == qrFixture, "locally rendered QR decodes to the exact synthetic login link")
        check(TelegramLoginQR.image(for: "https://example.com/login") == nil, "non-Telegram URLs cannot become login QR codes")
        check(!TelegramLoginQR.isValid(qrFixture + "&token=other") && !TelegramLoginQR.isValid("tg://login?token=short"), "ambiguous and malformed login tokens are rejected")
        let reference = Date(timeIntervalSince1970: 1000)
        let delivery = TelegramCodeDelivery(["type": ["@type": "authenticationCodeTypeTelegramMessage"], "next_type": ["@type": "authenticationCodeTypeSms"], "timeout": 60], now: reference)
        check(delivery.instructions.contains("verified Telegram service chat") && delivery.nextMethod == "SMS", "code guidance distinguishes Telegram delivery from the next SMS method")
        check(delivery.remaining(at: reference.addingTimeInterval(59.5)) == 1 && delivery.remaining(at: reference.addingTimeInterval(60)) == 0, "resend countdown honors the complete server timeout")
        check(TelegramCodeDelivery(["type": ["@type": "authenticationCodeTypeSms"]]).instructions.contains("by SMS"), "SMS delivery has its own accurate instructions")
        check(TelegramCodeDelivery(["type": ["@type": "authenticationCodeTypeFirebaseIos"]]).instructions.contains("official mobile app"), "mobile-only verification directs the user to QR login")
        check(TelegramCodeDelivery([:]).resendAvailableAt == nil, "missing next delivery method cannot enable resending")

        let hiddenLink = TelegramLinkPreview(["url": "https://example.com/actual", "display_url": "different.example/label", "title": "A page", "skip_confirmation": false])!
        check(!hiddenLink.skipConfirmation && hiddenLink.destinationURL?.absoluteString == "https://example.com/actual", "hidden links require confirmation using the real target, not the display label")
        let visibleLink = TelegramLinkPreview(["url": "https://example.com/visible", "skip_confirmation": true])!
        check(visibleLink.skipConfirmation && visibleLink.destinationURL != nil, "Telegram can explicitly permit opening a visible URL directly")
        check(!TelegramLinkPreview(["url": "https://example.com"])!.skipConfirmation, "missing confirmation metadata defaults to asking the user")
        check(TelegramLinkPreview(["display_url": "example.com", "title": "Label only"])!.destinationURL == nil, "display-only preview labels never become navigation targets")
        check(TelegramLinkPreview(["url": "file:///tmp/synthetic"])!.destinationURL == nil && TelegramLinkPreview(["url": "custom-app://action"])!.destinationURL == nil, "preview cards cannot launch files or arbitrary application schemes")
        check(TelegramLinkPreview(["url": "https://visible.example@actual.example/page"])!.destinationURL == nil, "credential-shaped URLs cannot disguise the destination host")
        check(TelegramLinkPreview(["url": "/relative/path"])!.destinationURL == nil, "relative preview targets are not opened")
        let previewWithPhoto = TelegramLinkPreview(["url": "https://example.com", "description": ["text": "Description 👋"], "type": ["@type": "linkPreviewTypeArticle", "photo": ["sizes": [["width": 100, "height": 80, "photo": ["id": 123, "size": 500]]]]]])!
        check(previewWithPhoto.photo?.id == 123 && previewWithPhoto.description == "Description 👋", "rich previews preserve the thumbnail and formatted description")

        func rawMessage(_ id: Int64, chat: Int64 = 1, text: String = "안녕 👋", outgoing: Bool = false, pending: Bool = false) -> TelegramObject {
            var message: TelegramObject = ["id": id, "chat_id": chat, "date": 1700000000 + id,
                "sender_id": ["@type": "messageSenderUser", "user_id": 7], "is_outgoing": outgoing,
                "content": ["@type": "messageText", "text": ["@type": "formattedText", "text": text]]]
            if pending { message["sending_state"] = ["@type": "messageSendingStatePending"] }
            return message
        }
        func rawChat(_ id: Int64, writable: Bool = true) -> TelegramObject {
            ["id": id, "title": id == 1 ? "Jamie 캘리포니아" : "Morgan", "type": ["@type": "chatTypePrivate", "user_id": 7],
             "permissions": ["can_send_basic_messages": writable, "can_send_photos": writable],
             "positions": [["list": ["@type": "chatListMain"], "order": "9007199254740991"]], "last_message": rawMessage(20, chat: id)]
        }
        check(TelegramMessage(rawMessage(9007199254740991)).id == 9007199254740991, "large message identifiers keep integer precision")
        check(TelegramMessage(rawMessage(1)).text == "안녕 👋", "Korean and emoji content remain unchanged")
        check(TelegramChat(rawChat(1)).title == "Jamie 캘리포니아", "Telegram's existing display name is preserved")
        check(TelegramChat(rawChat(1)).order == 9007199254740991, "int64 chat ordering strings decode exactly")
        check(TelegramMessage.content(["@type": "messageUnsupported"]).0.contains("Open in Telegram"), "unsupported content has a readable fallback")
        var disappearing = rawMessage(5)
        disappearing["self_destruct_type"] = ["@type": "messageSelfDestructTypeImmediately"]
        check(TelegramMessage(disappearing).text.contains("Self-destructing") && TelegramMessage(disappearing).photo == nil, "self-destructing content is not downloaded")

        let transport = FixtureTelegramTransport(), model = TelegramModel(transport: transport, storage: storage)
        model.connect()
        await settle()
        check(transport.requests.filter { $0.string("@type") == "setTdlibParameters" }.count == 1, "connection initializes the encrypted session once")
        transport.emitAuth("authorizationStateWaitTdlibParameters")
        await settle()
        check(transport.requests.filter { $0.string("@type") == "setTdlibParameters" }.count == 1, "duplicate authorization updates do not resubmit credentials")
        transport.emitAuth("authorizationStateWaitPhoneNumber")
        check(model.phase == .phone, "phone authorization step is rendered")
        model.requestQRCode(); model.requestQRCode(); await settle()
        check(transport.requests.filter { $0.string("@type") == "requestQrCodeAuthentication" }.count == 1, "QR login uses the official request and ignores double clicks")
        check((transport.requests.last?["other_user_ids"] as? [Int64])?.isEmpty == true, "QR authentication sends no unrelated user identifiers")
        transport.emit(["@type": "authorizationStateWaitOtherDeviceConfirmation", "link": qrFixture])
        check(model.phase == .qr && model.qrLink == qrFixture, "other-device confirmation displays the login QR")
        transport.emit(["@type": "authorizationStateWaitOtherDeviceConfirmation", "link": qrRotated])
        check(model.qrLink == qrRotated && !model.canRequestQRCode, "server token rotation replaces the old QR without overlapping requests")
        transport.emit(["@type": "authorizationStateWaitOtherDeviceConfirmation", "link": "https://example.com"])
        check(model.qrLink == nil && model.error != nil, "invalid updates remove the previous QR and report a safe error")
        transport.emit(["@type": "authorizationStateWaitOtherDeviceConfirmation", "link": qrRotated])
        transport.emitAuth("authorizationStateWaitPassword")
        check(model.phase == .password && model.qrLink == nil && model.error == nil, "QR approval transitions into two-step verification and clears the token")
        transport.emitAuth("authorizationStateWaitPhoneNumber")
        model.authenticate("+15555550123"); await settle()
        check(transport.requests.last?.string("@type") == "setAuthenticationPhoneNumber", "phone input uses the official authorization request")
        transport.emitAuth("authorizationStateWaitCode")
        model.authenticate("00000"); await settle()
        check(transport.requests.last?.string("@type") == "checkAuthenticationCode", "verification code is sent only to the auth method")
        transport.emit(["@type": "authorizationStateWaitCode", "code_info": ["type": ["@type": "authenticationCodeTypeTelegramMessage"], "next_type": ["@type": "authenticationCodeTypeSms"], "timeout": 60]])
        check(!model.canResendCode() && model.codeDelivery?.nextMethod == "SMS", "auth state retains delivery metadata and blocks premature resends")
        let beforeResend = transport.requests.count
        model.resendCode(); await settle()
        check(transport.requests.count == beforeResend, "resending before the deadline makes no API request")
        transport.emit(["@type": "authorizationStateWaitCode", "code_info": ["type": ["@type": "authenticationCodeTypeTelegramMessage"], "next_type": ["@type": "authenticationCodeTypeSms"], "timeout": 0]])
        model.resendCode(); model.resendCode(); await settle()
        check(transport.requests.filter { $0.string("@type") == "resendAuthenticationCode" }.count == 1 && model.resendRequested, "allowed resend submits once while awaiting the server update")
        check(transport.requests.last?.object("reason").string("@type") == "resendCodeReasonUserRequest", "code resending includes the official user-request reason")
        transport.emit(["@type": "authorizationStateWaitCode", "code_info": ["type": ["@type": "authenticationCodeTypeSms"]]])
        check(model.codeDelivery?.instructions.contains("by SMS") == true && !model.canResendCode(), "resend response updates delivery instructions and removes unavailable retries")
        model.requestQRCode(); await settle()
        check(transport.requests.last?.string("@type") == "requestQrCodeAuthentication", "a missing phone code can switch directly to QR login")
        transport.handler = { request in
            if request.string("@type") == "requestQrCodeAuthentication" {
                transport.emit(["@type": "authorizationStateWaitOtherDeviceConfirmation", "link": qrRotated])
                throw TelegramFailure.timeout
            }
            return ["@type": "ok"]
        }
        model.requestQRCode(); await settle()
        check(model.phase == .qr && model.qrLink == qrRotated && model.error == nil, "a late auth error cannot overwrite a newer QR authorization state")
        transport.handler = nil
        transport.emitAuth("authorizationStateWaitPassword")
        check(model.phase == .password, "two-step verification has its own secure input state")
        transport.emitAuth("authorizationStateWaitEmailCode")
        model.authenticate("00000"); await settle()
        check(transport.requests.last?.object("code").string("@type") == "emailAddressAuthenticationCode", "email verification uses the correct nested schema")
        check(secrets.values.count == 2, "phone numbers, codes, and passwords are not persisted by the app")
        transport.handler = { request in
            if request.string("@type") == "loadChats" { throw TelegramFailure.notFound }
            return ["@type": "ok"]
        }
        transport.emitAuth("authorizationStateReady"); await settle()
        check(model.isReady && !model.hasMoreChats && model.error == nil, "chat-list completion does not show a connection error")
        transport.emit(["@type": "updateNewChat", "chat": rawChat(1)])
        transport.emit(["@type": "updateNewChat", "chat": rawChat(2, writable: false)])
        transport.emit(["@type": "updateUser", "user": ["id": 7, "first_name": "Jamie", "last_name": "Kim"]])
        check(model.chats.count == 2 && model.senderName(TelegramMessage(rawMessage(1))) == "Jamie Kim", "chat and sender names come from Telegram updates")
        transport.handler = { request in
            guard request.string("@type") == "getChatHistory" else { return ["@type": "ok"] }
            let before = request.number("from_message_id")
            let ids: [Int64] = before == 0 ? [30, 20] : before == 20 ? [20, 10] : [10]
            return ["@type": "messages", "messages": ids.map { rawMessage($0) }]
        }
        model.loadHistory(1); model.loadHistory(1); await settle()
        check(model.histories[1]?.messages.map(\.id) == [20, 30], "initial history is ordered chronologically")
        check(transport.requests.filter { $0.string("@type") == "getChatHistory" }.count == 1, "duplicate history requests are prevented")
        transport.emit(["@type": "updateNewMessage", "message": rawMessage(40)])
        model.loadHistory(1, older: true); await settle()
        check(model.histories[1]?.messages.map(\.id) == [10, 20, 30, 40], "older pages deduplicate boundaries and retain concurrent new messages")
        model.loadHistory(1, older: true); await settle()
        check(model.histories[1]?.hasMore == false, "history stops when the cursor no longer advances")
        transport.emit(["@type": "updateDeleteMessages", "chat_id": 1, "message_ids": [20], "is_permanent": true])
        transport.emit(["@type": "updateNewMessage", "message": rawMessage(20)])
        check(!(model.histories[1]?.messages.contains { $0.id == 20 } ?? true), "deleted messages cannot reappear from late updates")
        transport.emit(["@type": "updateMessageContent", "chat_id": 1, "message_id": 30, "new_content": ["@type": "messageText", "text": ["text": "Edited"]]])
        check(model.histories[1]?.messages.first { $0.id == 30 }?.text == "Edited", "message edits replace loaded content")
        model.search = "Edited"
        check(model.sortedChats.map(\.id) == [1] && model.histories[1]?.messages.count == 3, "search filters chats without removing conversation context")
        model.search = ""
        model.setDraft("First draft", chatID: 1); model.setDraft("Other draft", chatID: 2)
        check(model.canSend(1) && !model.canSend(2), "Telegram permissions gate sending per conversation")
        transport.handler = { request in
            if request.string("@type") == "sendMessage" { return rawMessage(50, outgoing: true, pending: true) }
            return ["@type": "ok"]
        }
        model.send(1); model.send(1); await settle()
        check(transport.requests.filter { $0.string("@type") == "sendMessage" }.count == 1, "double clicking sends one request")
        check(model.sending.contains(1) && model.draft(1) == "First draft", "pending sends preserve the draft until confirmed")
        transport.emit(["@type": "updateMessageSendSucceeded", "old_message_id": 999, "message": rawMessage(100, outgoing: true)])
        check(model.draft(1) == "First draft", "unrelated send events cannot clear this draft")
        transport.emit(["@type": "updateMessageSendSucceeded", "old_message_id": 50, "message": rawMessage(51, outgoing: true)])
        check(model.draft(1).isEmpty && model.draft(2) == "Other draft" && !model.sending.contains(1), "confirmed sends clear only the captured conversation draft")
        model.setDraft("Keep on timeout", chatID: 1)
        transport.handler = { request in
            if request.string("@type") == "sendMessage" { throw TelegramFailure.timeout }
            return ["@type": "ok"]
        }
        model.send(1); await settle()
        check(model.uncertain.contains(1) && !model.canSend(1) && model.draft(1) == "Keep on timeout", "unknown outcomes block duplicate retries and preserve text")
        let sendCount = transport.requests.filter { $0.string("@type") == "sendMessage" }.count
        model.send(1); await settle()
        check(transport.requests.filter { $0.string("@type") == "sendMessage" }.count == sendCount, "unknown sends are not resubmitted automatically")
        model.acknowledgeUnknown(1)
        check(model.canSend(1), "explicit acknowledgement restores manual sending")
        transport.handler = { request in
            if request.string("@type") == "sendMessage" {
                transport.emit(["@type": "updateMessageSendSucceeded", "old_message_id": 60, "message": rawMessage(61, outgoing: true)])
                return rawMessage(60, outgoing: true, pending: true)
            }
            return ["@type": "ok"]
        }
        model.send(1); await settle()
        check(!model.sending.contains(1) && model.draft(1).isEmpty, "send confirmation arriving before the request response still completes")
        check(!(model.histories[1]?.messages.contains { $0.id == 60 } ?? true), "early send confirmation does not leave a duplicate pending bubble")

        let photoURL = temp.appendingPathComponent("fixture.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: photoURL)
        model.setDraft("Text remains after photo", chatID: 1)
        model.selectPhoto(photoURL, chatID: 1)
        transport.handler = { request in
            if request.string("@type") == "sendMessage" { return rawMessage(70, outgoing: true, pending: true) }
            return ["@type": "ok"]
        }
        model.send(1); await settle()
        let photoRequest = transport.requests.last { $0.string("@type") == "sendMessage" }!
        let outgoingPath = photoRequest.object("input_message_content").object("photo").object("photo").string("path")
        check(outgoingPath.hasPrefix(temp.appendingPathComponent("files/outgoing").path) && outgoingPath != photoURL.path, "photo sending uses a verified private copy instead of the original file")
        check(photoRequest.object("input_message_content").object("caption").string("text").isEmpty, "photo submission does not also send the draft text")
        transport.emit(["@type": "updateMessageSendSucceeded", "old_message_id": 70, "message": rawMessage(71, outgoing: true)])
        check(model.photos[1] == nil && model.draft(1) == "Text remains after photo", "confirmed photo send clears only the photo")
        check(!FileManager.default.fileExists(atPath: outgoingPath) && FileManager.default.fileExists(atPath: photoURL.path), "completed upload removes only the temporary copy")
        model.selectPhoto(photoURL, chatID: 1)
        try Data("Changed fixture".utf8).write(to: photoURL)
        let requestsBeforeChange = transport.requests.filter { $0.string("@type") == "sendMessage" }.count
        model.send(1); await settle()
        check(transport.requests.filter { $0.string("@type") == "sendMessage" }.count == requestsBeforeChange && model.photos[1] != nil, "changed photos are rejected before any send request")
        model.removePhoto(1)
        let sendRequest = transport.requests.first { $0.string("@type") == "sendMessage" }!
        check(sendRequest.object("options").number("paid_message_star_count") == 0 && !sendRequest.object("options").flag("allow_paid_broadcast"), "sending cannot opt into paid messages")
        transport.emit(["@type": "updateChatPermissions", "chat_id": 1, "permissions": ["can_send_basic_messages": false, "can_send_photos": false]])
        check(!model.canSend(1), "permission changes immediately disable composition")
        transport.handler = { request in
            if request.string("@type") == "getChatHistory" {
                try await Task.sleep(nanoseconds: 200_000_000)
                return ["@type": "messages", "messages": [rawMessage(6, chat: 2)]]
            }
            return ["@type": "ok"]
        }
        model.loadHistory(2)
        await model.disconnect(); try? await Task.sleep(nanoseconds: 250_000_000)
        check(model.phase == .configuration && model.histories.isEmpty && model.chats.isEmpty, "late history responses cannot repopulate a disconnected account")
        check(model.drafts.isEmpty && model.photos.isEmpty && model.files.isEmpty, "disconnect clears in-memory drafts and media references")
        check(model.qrLink == nil && model.codeDelivery == nil, "disconnect clears all transient login presentation data")
        transport.emit(["@type": "updateNewChat", "chat": rawChat(9)])
        check(model.chats.isEmpty, "late chat updates are ignored after disconnect")

        // Exercise the actual bundled C interface without API credentials, an
        // account login, or any message request.
        if CommandLine.arguments.count > 1 {
            let client = TelegramClient(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            for _ in 0..<2 {
                try client.start()
                let version = try await client.request(["@type": "getOption", "name": "version"])
                check(version.string("value").hasPrefix("1.8.67"), "bundled TDLib responds through the real JSON interface")
                await client.close()
            }
        }
        print("SUCCESS: \(count) Telegram checks; no real account, Keychain entry, or message accessed")
    }
}
