import Foundation

final class FakeContacts: ContactProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var access: ContactAccess = .notRequested
    private var names: [String: ContactIdentity] = [:]
    private(set) var prompts = 0
    private(set) var lookups = 0
    var delayed = false
    func configure(_ access: ContactAccess, names: [String: ContactIdentity]) {
        lock.lock(); defer { lock.unlock() }
        self.access = access; self.names = names
    }
    func authorization() -> ContactAccess {
        lock.lock(); defer { lock.unlock() }
        return access
    }
    private func authorize() {
        lock.lock(); defer { lock.unlock() }
        prompts += 1; access = .authorized
    }
    func requestAccess() async -> Bool { authorize(); return true }
    private func capturedNames() -> [String: ContactIdentity] {
        lock.lock(); defer { lock.unlock() }
        lookups += 1; return names
    }
    func lookup(_ handles: Set<String>) async throws -> [String: ContactIdentity] {
        let captured = capturedNames()
        if delayed { try await Task.sleep(nanoseconds: 80_000_000) }
        return captured.filter { handles.contains($0.key) }
    }
}

@main
struct ContactTests {
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
            fatalError("Timed out waiting for contacts state")
        }
        let address = "+15555550123"
        let id = "any;-;\(address)"
        let message = ChatMessage(id: "contact-fixture", conversationID: id, conversationTitle: address,
            sender: address, text: "Fixture", date: Date(), isFromMe: false, bodyUnavailable: false,
            hasAttachment: false, conversationService: "RCS", conversationAddress: address)
        let names = [address: ContactIdentity(name: "홍길동")]
        check(ContactIdentity.from(matchingNames: ["Jamie", "Jamie"])?.name == "Jamie", "duplicate contacts across accounts still display one name")
        check(ContactIdentity.from(matchingNames: [" Jamie ", "JAMIE", ""])?.name.lowercased() == "jamie", "equivalent whitespace and case variants collapse")
        check(ContactIdentity.from(matchingNames: ["Jamie California", "Jamie 캘리포니아"])?.name == "Jamie California / Jamie 캘리포니아", "different saved labels for the same number are both displayed")
        check(ContactIdentity.from(matchingNames: ["", "  "]) == nil, "empty contact records do not replace the number")
        check(ContactIdentity.from(matchingNames: ["Jamie 캘리포니아", "Jamie California"])?.initials == "JC", "multiple labels have stable initials from the first displayed label")
        check(NamePresentation.title(for: message, names: names) == "홍길동", "phone conversation uses saved contact name")
        check(NamePresentation.title(for: message, names: [:]) == address, "unregistered phone stays visible")
        check(NamePresentation.initials(for: "홍길동") == "홍", "Korean initials use a complete character")
        check(NamePresentation.initials(for: "John Smith") == "JS", "Latin full name initials")
        check(NamePresentation.initials(for: "Wayfair") == "W", "business single initial")
        check(NamePresentation.initials(for: address) == nil && NamePresentation.initials(for: "62297") == nil, "phone and shortcode use person icon instead of plus or digit")
        check(NamePresentation.initials(for: "person@example.invalid") == nil, "unregistered email uses person icon")
        check(NamePresentation.initials(for: "Synapse 프로젝트") == "S", "mixed language title has readable initial")
        var business = message
        business.conversationDisplayName = "Wayfair"
        check(NamePresentation.title(for: business, names: names) == "Wayfair", "explicit business title preserved")
        let group = ChatMessage(id: "group-fixture", conversationID: "any;+;synthetic-group", conversationTitle: "Study group",
            sender: address, text: "Group fixture", date: Date(), isFromMe: false, bodyUnavailable: false, hasAttachment: false)
        check(NamePresentation.title(for: group, names: names) == "Study group", "group is not renamed to one sender")
        let email = "person@example.invalid"
        let emailMessage = ChatMessage(id: "email-fixture", conversationID: "any;-;\(email)", conversationTitle: email,
            sender: email, text: "Email fixture", date: Date(), isFromMe: true, bodyUnavailable: false, hasAttachment: false)
        check(NamePresentation.title(for: emailMessage, names: [email: ContactIdentity(name: "Jane Doe")]) == "Jane Doe", "email conversation name resolves without an incoming message")
        let snapshot = Snapshot(messages: [message, group, emailMessage], sourceRows: 3, limit: 2000)
        check(NamePresentation.handles(in: snapshot) == [address, email], "lookup requests contain only unique phone and email handles")
        let contacts = FakeContacts()
        contacts.configure(.notRequested, names: names)
        let model = InboxModel(messageNameProvider: NoMessageNames(), startTimer: false, loader: { _ in snapshot }, contacts: contacts)
        model.connect()
        await waitFor { !model.isLoading }
        await waitFor { !model.isLoadingContacts }
        check(contacts.prompts == 1 && model.contactNames == names, "live connection requests contact permission and loads names after authorization")
        model.refreshContactNames()
        await waitFor { !model.isLoadingContacts }
        check(contacts.prompts == 1, "authorized contact refresh does not prompt again")
        check(model.conversations.first { $0.id == id }?.title == "홍길동", "sidebar title uses contact name")
        check(model.senderName(address) == "홍길동", "group sender label uses the same contact name")
        model.setDraft("Keep this draft", for: id)
        check(model.canSend(to: id), "name resolution does not change the send target")
        model.search = "홍길동"
        check(model.conversations.contains { $0.id == id } && model.conversations.contains { $0.id == group.conversationID }, "contact name searches find direct and group conversations")
        check(model.matchesSearch(group, title: "Study group"), "matching group sender remains visible in message results")
        model.search = "555550123"
        check(model.conversations.contains { $0.id == id }, "number remains searchable after name resolution")
        model.refreshContactNames()
        check(contacts.lookups == 1, "refresh reuses cached matches and misses")
        contacts.configure(.authorized, names: [address: ContactIdentity(name: "Jane Doe")])
        model.refreshContactNames(invalidate: true)
        await waitFor { !model.isLoadingContacts }
        check(model.senderName(address) == "Jane Doe" && model.draft(for: id) == "Keep this draft", "contact edits refresh name without losing the draft")
        contacts.configure(.denied, names: [:])
        model.refreshContactNames()
        check(model.contactNames.isEmpty && model.contactAccess == .denied && model.canSend(to: id), "permission revocation clears names and keeps sending available")
        contacts.configure(.authorized, names: names)
        contacts.delayed = true
        model.refreshContactNames(invalidate: true)
        await Task.yield()
        model.disconnect()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(model.contactNames.isEmpty && model.isDemo, "late contact result cannot restore names after disconnect")
        model.connect(path: "/synthetic/imported.db")
        await waitFor { !model.isLoading }
        let previousLookups = contacts.lookups
        model.refreshContactNames(requestPermission: true)
        check(contacts.lookups == previousLookups && model.contactNames.isEmpty, "imported database does not query personal Contacts")
        let denied = FakeContacts()
        denied.configure(.denied, names: [:])
        let deniedModel = InboxModel(messageNameProvider: NoMessageNames(), startTimer: false, loader: { _ in snapshot }, contacts: denied)
        deniedModel.connect()
        await waitFor { !deniedModel.isLoading }
        deniedModel.refresh()
        await waitFor { !deniedModel.isLoading }
        check(denied.prompts == 0 && denied.lookups == 0 && deniedModel.contactAccess == .denied, "denied permission stays visible without repeat prompts or contact reads")
        print("SUCCESS: \(checks) contact presentation checks; no real contacts accessed")
    }
}
