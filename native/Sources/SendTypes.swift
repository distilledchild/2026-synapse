import Foundation

struct SendRequest: Codable, Sendable, Equatable {
    let id: UUID
    let chatID: String
    let text: String
    var service: String? = nil
    var photo: PhotoAttachment? = nil

    static let maximumBytes = 16_384
    static let supportedServices: Set<String> = ["iMessage", "SMS", "RCS"]
    var isValid: Bool {
        Self.isSupportedChat(chatID, service: service) &&
            (photo.map { $0.isValid && text.isEmpty } ?? Self.isValidText(text))
    }
    static func isValidText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        text.utf8.count <= maximumBytes && !text.contains("\0")
    }
    static func isSupportedChat(_ id: String, service: String? = nil) -> Bool {
        let parts = id.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        // Modern chat.db GUIDs use "any" for iMessage, SMS and RCS alike.
        // Require chat.service_name for those IDs; never guess the service from the handle.
        let prefix = String(parts[0])
        let supportsService = (supportedServices.contains(prefix) && (service == nil || service == prefix)) ||
            (prefix == "any" && service.map(supportedServices.contains) == true)
        return supportsService &&
            (parts[1] == "+" || parts[1] == "-") && !parts[2].isEmpty &&
            id.utf8.count <= 1024 && !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum SendOutcome: String, Codable, Sendable {
    case accepted, ready, permissionDenied, targetUnavailable, invalidRequest, attachmentUnavailable, unavailable, unknown
    var message: String {
        switch self {
        case .accepted: return "Sent to Apple Messages. Check delivery status in Messages."
        case .ready: return "The recipient was verified in Messages. Nothing was sent."
        case .permissionDenied: return "Allow Synapse to access Messages in System Settings → Privacy & Security → Automation."
        case .targetUnavailable: return "This conversation could not be found in Messages. Open it in Messages, then refresh Synapse."
        case .invalidRequest: return "Check the message and recipient. Messages must contain text and be no larger than 16 KB."
        case .attachmentUnavailable: return "The selected photo changed or cannot be read. Select it again."
        case .unavailable: return "Unable to start the sending helper. Reinstall Synapse and try again."
        case .unknown: return "The send result is unknown. Check Messages before trying again to avoid sending a duplicate. Synapse will not retry automatically."
        }
    }
}

protocol MessageSending: Sendable {
    func send(_ request: SendRequest) async -> SendOutcome
}

// Fixed script; recipient and message are Apple event string descriptors, never source code.
enum MessageScript {
    static let source = """
    on deliverMessage(chatID, messageText, validationOnly, photoPath)
        with timeout of 30 seconds
            try
                tell application id "com.apple.MobileSMS"
                    set targetChat to chat id chatID
                    if (id of targetChat as text) is not equal to chatID then return "targetUnavailable"
                    -- Keep the exact existing chat, including its current SMS/RCS route.
                    -- Do not choose a different account or recipient based on cached service_name.
                    -- Forwarded SMS/RCS account flags can be false while the chat is usable.
                    -- Let Messages evaluate transport availability when handling send.
                end tell
            on error errorText number errorCode
                if errorCode is -1743 then return "permissionDenied"
                return "targetUnavailable"
            end try
            if photoPath is not equal to "" then
                try
                    set photoFile to POSIX file photoPath as alias
                on error
                    return "attachmentUnavailable"
                end try
            end if
            if validationOnly then return "ready"
            try
                tell application id "com.apple.MobileSMS"
                    if photoPath is equal to "" then
                        send messageText to targetChat
                    else
                        send photoFile to targetChat
                    end if
                end tell
                return "accepted"
            on error errorText number errorCode
                if errorCode is -1743 then return "permissionDenied"
                return "unknown"
            end try
        end timeout
    end deliverMessage
    """

    static func event(for request: SendRequest, validationOnly: Bool = false) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272,
            targetDescriptor: nil, returnID: -1, transactionID: 0) // ascr / psbr
        event.setParam(NSAppleEventDescriptor(string: "delivermessage"), forKeyword: 0x736e616d) // snam
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: request.chatID), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: request.text), at: 2)
        arguments.insert(NSAppleEventDescriptor(boolean: validationOnly), at: 3)
        arguments.insert(NSAppleEventDescriptor(string: request.photo?.path ?? ""), at: 4)
        event.setParam(arguments, forKeyword: 0x2d2d2d2d) // ----
        return event
    }
}
