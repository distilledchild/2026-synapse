import Foundation
import Security

typealias TelegramObject = [String: Any]

struct TelegramCredentials: Codable, Equatable {
    let apiID: Int32
    let apiHash: String
    var isValid: Bool {
        apiID > 0 && apiHash.count == 32 && apiHash.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
        }
    }
}

enum TelegramFailure: Error, LocalizedError, Equatable {
    case unavailable, keychain, storage, invalidCredentials, closed, timeout
    case phone, code, password, rateLimited, rejected, unsupported, photo, notFound
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The Telegram library could not be loaded. Reinstall Synapse."
        case .keychain: return "Synapse could not access its Telegram credentials in Keychain."
        case .storage: return "Synapse could not open its private Telegram data folder."
        case .invalidCredentials: return "Enter a positive API ID and a 32-character API hash."
        case .closed: return "Telegram is disconnected. Connect again to continue."
        case .timeout: return "Telegram did not respond in time. Check your connection."
        case .phone: return "Check your phone number, including its country code."
        case .code: return "The verification code is incorrect or expired. Try again."
        case .password: return "The two-step verification password is incorrect."
        case .rateLimited: return "Telegram asked you to wait before trying again."
        case .rejected: return "Telegram could not complete this request. Check your connection and permissions."
        case .unsupported: return "Complete this sign-in step in the official Telegram app, then reconnect."
        case .photo: return "The selected photo is unavailable or has changed. Select it again."
        case .notFound: return "Telegram could not find the requested item."
        }
    }
    // Server responses may contain user input. Only expose fixed, allowlisted messages.
    static func from(_ object: TelegramObject) -> TelegramFailure {
        let message = object["message"] as? String ?? ""
        if (object["code"] as? Int) == 404 { return .notFound }
        if (object["code"] as? Int) == 429 || message.hasPrefix("FLOOD_WAIT") { return .rateLimited }
        if message.contains("API_ID") || message.contains("API_HASH") { return .invalidCredentials }
        if message.contains("PHONE_NUMBER") { return .phone }
        if message.contains("CODE") { return .code }
        if message.contains("PASSWORD") { return .password }
        return .rejected
    }
}

protocol TelegramSecretStoring {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
}

struct TelegramKeychain: TelegramSecretStoring {
    private let service = "com.distilledchild.synapse.telegram"
    func read(_ account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw TelegramFailure.keychain }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let query = base(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw TelegramFailure.keychain }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw TelegramFailure.keychain }
    }
    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

struct TelegramStorage {
    let secrets: any TelegramSecretStoring
    let root: URL
    init(secrets: any TelegramSecretStoring = TelegramKeychain(), root: URL? = nil) {
        self.secrets = secrets
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Synapse/Telegram", isDirectory: true)
    }
    func loadCredentials() throws -> TelegramCredentials? {
        guard let data = try secrets.read("api-credentials") else { return nil }
        guard let credentials = try? JSONDecoder().decode(TelegramCredentials.self, from: data), credentials.isValid else {
            throw TelegramFailure.invalidCredentials
        }
        return credentials
    }
    func saveCredentials(_ credentials: TelegramCredentials) throws {
        guard credentials.isValid else { throw TelegramFailure.invalidCredentials }
        try secrets.write(JSONEncoder().encode(credentials), account: "api-credentials")
    }
    func encryptionKey() throws -> Data {
        if let key = try secrets.read("database-key") {
            guard key.count == 32 else { throw TelegramFailure.keychain }
            return key
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw TelegramFailure.keychain }
        let key = Data(bytes)
        try secrets.write(key, account: "database-key")
        return key
    }
    func prepare() throws {
        do {
            for folder in [root, root.appendingPathComponent("database"), root.appendingPathComponent("files")] {
                guard !((try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false) else {
                    throw TelegramFailure.storage
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
                var url = folder, values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            }
        } catch { throw TelegramFailure.storage }
    }
    func parameters(credentials: TelegramCredentials, key: Data) -> TelegramObject {
        ["@type": "setTdlibParameters", "use_test_dc": false,
         "database_directory": root.appendingPathComponent("database").path,
         "files_directory": root.appendingPathComponent("files").path,
         "database_encryption_key": key.base64EncodedString(),
         "use_file_database": true, "use_chat_info_database": true, "use_message_database": true,
         "use_secret_chats": false, "api_id": credentials.apiID, "api_hash": credentials.apiHash,
         "system_language_code": "en", "device_model": "Mac", "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
         "application_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.3"]
    }
}
