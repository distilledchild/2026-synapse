import Foundation
import ImageIO
import CryptoKit

struct PhotoAttachment: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let path: String
    let name: String
    let byteCount: Int
    let digest: String

    var isValid: Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 4096 &&
        !name.isEmpty && (1...PhotoFile.maximumBytes).contains(byteCount) &&
        digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }
}

enum PhotoFileError: Error, LocalizedError {
    case unavailable, tooLarge, unsupported, changed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Unable to read this photo. Choose a photo downloaded to this Mac."
        case .tooLarge: return "Photos must be no larger than 20 MB."
        case .unsupported: return "Choose a JPG, PNG, HEIC, GIF, or WebP photo."
        case .changed: return "This photo changed or moved. Select it again."
        }
    }
}

enum PhotoFile {
    static let maximumBytes = 20 * 1024 * 1024
    private static let supportedTypes: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.heif", "com.compuserve.gif", "org.webmproject.webp"]

    private static func read(_ url: URL) throws -> Data {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw PhotoFileError.unavailable }
        guard size <= maximumBytes else { throw PhotoFileError.tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw PhotoFileError.unavailable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), !data.isEmpty else { throw PhotoFileError.unavailable }
        guard data.count <= maximumBytes else { throw PhotoFileError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), supportedTypes.contains(type as String),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000_000 / height,
              thumbnail(data) != nil else { throw PhotoFileError.unsupported }
        return data
    }

    static func select(_ url: URL) throws -> PhotoAttachment {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let data = try read(url)
        return PhotoAttachment(id: UUID(), path: url.path, name: url.lastPathComponent,
            byteCount: data.count, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func verifiedData(_ photo: PhotoAttachment) throws -> Data {
        guard photo.isValid else { throw PhotoFileError.changed }
        let data = try read(URL(fileURLWithPath: photo.path))
        guard data.count == photo.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == photo.digest else { throw PhotoFileError.changed }
        return data
    }

    static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 400
        ] as CFDictionary)
    }
}
