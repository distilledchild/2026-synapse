import SwiftUI
import ImageIO

enum AttachmentImageLoader {
    static var messagesRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/Attachments")
    }

    static func image(for attachment: MessageAttachment, root: URL = messagesRoot) -> CGImage? {
        guard attachment.isImage, let path = attachment.filename, !path.isEmpty else { return nil }
        // Database paths can be missing or untrusted. Read only files in the attachment directory.
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        let allowed = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(allowed),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 50 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

struct AttachmentPreview: View {
    let attachment: MessageAttachment
    let allowsLocalFiles: Bool
    var imageRoot: URL = AttachmentImageLoader.messagesRoot
    @State private var image: CGImage?
    @State private var loading = true
    @State private var attempt = 0
    @State private var expanded = false

    var body: some View {
        Group {
            if let image {
                Button { expanded = true } label: {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: 320, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).help("View full image")
                    .accessibilityLabel("Attached image: \(attachment.displayName)")
            } else if loading && allowsLocalFiles {
                ProgressView().controlSize(.small).frame(width: 160, height: 90)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Label(attachment.displayName, systemImage: "photo").lineLimit(2)
                    Text(allowsLocalFiles ? "Unable to load this image. Check its download status and access permissions in Messages." : "Connect Messages to view images.")
                    if allowsLocalFiles { Button("Reload") { attempt += 1 } }
                }.font(.caption).frame(maxWidth: 300, alignment: .leading)
            }
        }
        .task(id: "\(attachment.id)-\(attachment.filename ?? "")-\(allowsLocalFiles)-\(attempt)") {
            image = nil
            guard allowsLocalFiles else { loading = false; return }
            loading = true
            let attachment = attachment
            let root = imageRoot
            let result = await Task.detached(priority: .utility) { AttachmentImageLoader.image(for: attachment, root: root) }.value
            guard !Task.isCancelled else { return }
            image = result
            loading = false
        }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 12) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(attachment.displayName)
                }
                HStack {
                    Text(attachment.displayName).lineLimit(1)
                    Spacer()
                    Button("Close") { expanded = false }.keyboardShortcut(.cancelAction)
                }
            }.padding(20).frame(width: 760, height: 580)
        }
    }
}
