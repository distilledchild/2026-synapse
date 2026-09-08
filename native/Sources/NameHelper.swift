import Foundation

// This executable has no send command or write operation.
@main
struct NameHelper {
    static func main() {
        let response: MessageNameResponse
        if CommandLine.arguments.count == 1,
           let data = try? FileHandle.standardInput.readToEnd(), data.count <= 65_536,
           let request = try? JSONDecoder().decode(MessageNameRequest.self, from: data), request.isValid,
           let script = NSAppleScript(source: MessageNameScript.source) {
            var error: NSDictionary?
            let result = script.executeAppleEvent(MessageNameScript.event(for: request), error: &error)
            if let error {
                response = MessageNameResponse(error: (error[NSAppleScript.errorNumber] as? Int) == -1743 ? .permissionDenied : .unavailable)
            } else { response = MessageNameScript.response(from: result, request: request) }
        } else { response = MessageNameResponse(error: .invalidRequest) }
        if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data) }
    }
}
