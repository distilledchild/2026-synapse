import Foundation

// A separate process keeps Automation prompts and AppleScript off the UI thread.
// NSAppleScript executes on this helper's main thread. No message data is logged.
@main
struct SenderHelper {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let validationOnly = arguments == ["--check-target"]
        let outcome: SendOutcome
        if (arguments.isEmpty || validationOnly),
           let data = try? FileHandle.standardInput.readToEnd(), data.count <= 131_072,
           let request = try? JSONDecoder().decode(SendRequest.self, from: data), request.isValid {
            outcome = send(request, validationOnly: validationOnly)
        } else {
            outcome = .invalidRequest
        }
        if let data = try? JSONEncoder().encode(outcome) { FileHandle.standardOutput.write(data) }
    }

    private static func send(_ request: SendRequest, validationOnly: Bool) -> SendOutcome {
        if let photo = request.photo, (try? PhotoFile.verifiedData(photo)) == nil { return .attachmentUnavailable }
        if let script = NSAppleScript(source: MessageScript.source) {
            var error: NSDictionary?
            let result = script.executeAppleEvent(MessageScript.event(for: request, validationOnly: validationOnly), error: &error)
            if let error {
                return (error[NSAppleScript.errorNumber] as? Int) == -1743 ? .permissionDenied : .unknown
            } else {
                return result.stringValue.flatMap(SendOutcome.init(rawValue:)) ?? .unknown
            }
        } else {
            return .invalidRequest
        }
    }
}
