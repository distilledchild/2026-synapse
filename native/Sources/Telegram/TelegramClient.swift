import Foundation
import Darwin
import Security
import CryptoKit

@MainActor
protocol TelegramTransport: AnyObject {
    var onUpdate: ((TelegramObject) -> Void)? { get set }
    func start() throws
    func request(_ object: TelegramObject) async throws -> TelegramObject
    func close() async
}

// One receive loop owns the TDLib JSON stream and forwards events to the main
// queue in order. No requests, responses, identifiers, or server errors are logged.
private final class TDLibRuntime: @unchecked Sendable {
    typealias Create = @convention(c) () -> Int32
    typealias Send = @convention(c) (Int32, UnsafePointer<CChar>?) -> Void
    typealias Receive = @convention(c) (Double) -> UnsafePointer<CChar>?
    typealias Execute = @convention(c) (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
    let create: Create
    let send: Send
    let receive: Receive
    let execute: Execute
    // Keep the library loaded for the process lifetime, including shutdown.
    private let handle: UnsafeMutableRawPointer
    init(url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw TelegramFailure.unavailable }
        self.handle = handle
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else { throw TelegramFailure.unavailable }
            return unsafeBitCast(address, to: T.self)
        }
        create = try symbol("td_create_client_id", Create.self)
        send = try symbol("td_send", Send.self)
        receive = try symbol("td_receive", Receive.self)
        execute = try symbol("td_execute", Execute.self)
        _ = "{\"@type\":\"setLogStream\",\"log_stream\":{\"@type\":\"logStreamEmpty\"}}".withCString(execute)
        _ = "{\"@type\":\"setLogVerbosityLevel\",\"new_verbosity_level\":0}".withCString(execute)
    }
}

@MainActor
final class TelegramClient: TelegramTransport {
    var onUpdate: ((TelegramObject) -> Void)?
    private var runtime: TDLibRuntime?
    private var clientID: Int32?
    private var pending: [String: CheckedContinuation<TelegramObject, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private let libraryURL: URL
    private let verifiesAppBundle: Bool
    init(libraryURL: URL? = nil) {
        verifiesAppBundle = libraryURL == nil
        self.libraryURL = libraryURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libtdjson.dylib")
    }
    func start() throws {
        guard clientID == nil else { return }
        if verifiesAppBundle { try verifyBundledLibraries() }
        let runtime = try TDLibRuntime(url: libraryURL)
        self.runtime = runtime
        let id = runtime.create()
        clientID = id
        Thread.detachNewThread { [weak self] in
            while true {
                guard let pointer = runtime.receive(0.5) else { continue }
                let data = Data(bytes: pointer, count: strlen(pointer))
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? TelegramObject,
                      (object["@client_id"] as? Int32) == id else { continue }
                let closed = (object["@type"] as? String) == "updateAuthorizationState" &&
                    ((object["authorization_state"] as? TelegramObject)?["@type"] as? String) == "authorizationStateClosed"
                DispatchQueue.main.async { [weak self] in self?.receive(object, id: id) }
                if closed { break }
            }
        }
        // TDLib sends authorization updates only after receiving its first request.
        "{\"@type\":\"getAuthorizationState\"}".withCString { runtime.send(id, $0) }
    }
    private func verifyBundledLibraries() throws {
        let app = Bundle.main.bundleURL
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess,
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Resources/TelegramLibraries.plist")),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              Set(manifest.keys) == ["libtdjson.dylib", "libssl.3.dylib", "libcrypto.3.dylib"] else { throw TelegramFailure.unavailable }
        for (name, digest) in manifest {
            let url = app.appendingPathComponent("Contents/Frameworks").appendingPathComponent(name)
            guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw TelegramFailure.unavailable
            }
        }
    }
    func request(_ object: TelegramObject) async throws -> TelegramObject {
        guard let runtime, let clientID else { throw TelegramFailure.closed }
        let token = UUID().uuidString
        var request = object; request["@extra"] = token
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request), let json = String(data: data, encoding: .utf8) else {
            throw TelegramFailure.rejected
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[token] = continuation
            timeouts[token] = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self else { return }
                self.timeouts[token] = nil
                self.pending.removeValue(forKey: token)?.resume(throwing: TelegramFailure.timeout)
            }
            json.withCString { runtime.send(clientID, $0) }
        }
    }
    private func receive(_ object: TelegramObject, id: Int32) {
        guard clientID == id else { return }
        if let token = object["@extra"] as? String, let continuation = pending.removeValue(forKey: token) {
            timeouts.removeValue(forKey: token)?.cancel()
            if object["@type"] as? String == "error" { continuation.resume(throwing: TelegramFailure.from(object)) }
            else { continuation.resume(returning: object) }
        } else { onUpdate?(object) }
        if object["@type"] as? String == "updateAuthorizationState",
           (object["authorization_state"] as? TelegramObject)?["@type"] as? String == "authorizationStateClosed" {
            clientID = nil
            for task in timeouts.values { task.cancel() }
            timeouts.removeAll()
            let requests = pending; pending.removeAll()
            for continuation in requests.values { continuation.resume(throwing: TelegramFailure.closed) }
        }
    }
    func close() async {
        guard let runtime, let id = clientID else { return }
        "{\"@type\":\"close\"}".withCString { runtime.send(id, $0) }
        // A new receive loop must never overlap the old one. A timeout leaves the
        // client in closing state until its actual authorizationStateClosed update.
        for _ in 0..<80 {
            if clientID == nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
