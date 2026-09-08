import Foundation

struct AppleMessageSender: MessageSending {
    var executableURL: URL? = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SynapseSender")
    var timeout: TimeInterval = 45

    func send(_ request: SendRequest) async -> SendOutcome {
        guard request.isValid else { return .invalidRequest }
        guard let executable = executableURL,
            let payload = try? JSONEncoder().encode(request) else { return .unavailable }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return SendOutcome.unavailable }
            // Bounded input; no text or recipient in process arguments or temporary files.
            do {
                try input.fileHandleForWriting.write(contentsOf: payload)
                try input.fileHandleForWriting.close()
            } catch {
                try? input.fileHandleForWriting.close()
                process.terminate()
                return .unknown
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            while process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                return .unknown
            }
            guard process.terminationStatus == 0,
                  let data = try? output.fileHandleForReading.readToEnd(),
                  let outcome = try? JSONDecoder().decode(SendOutcome.self, from: data) else { return .unknown }
            return outcome
        }.value
    }
}
