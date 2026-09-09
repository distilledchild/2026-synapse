import SwiftUI
import ImageIO

private final class LinkPreviewSecrets: TelegramSecretStoring {
    func read(_ account: String) throws -> Data? { nil }
    func write(_ data: Data, account: String) throws {}
}

@MainActor private final class LinkPreviewTransport: TelegramTransport {
    var onUpdate: ((TelegramObject) -> Void)?
    func start() throws {}
    func request(_ object: TelegramObject) async throws -> TelegramObject { ["@type": "ok"] }
    func close() async {}
}

// Synthetic UI regression fixture: opens are captured as text, never forwarded
// to a browser. It has no account credentials and never accesses real messages.
@main private struct TelegramLinkUITestApp: App {
    @StateObject private var model: TelegramModel
    @State private var opens: [String] = []
    @State private var useMissingFile = false
    private let file: TelegramFile
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-link-preview-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("synthetic-red.png")
        let context = CGContext(data: nil, width: 100, height: 60, bitsPerComponent: 8, bytesPerRow: 400,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let model = TelegramModel(transport: LinkPreviewTransport(), storage: TelegramStorage(secrets: LinkPreviewSecrets(), root: root))
        model.receive(["@type": "authorizationStateReady"])
        let raw: TelegramObject = ["id": 777, "size": 1024, "local": ["is_downloading_completed": true, "path": url.path]]
        model.receive(["@type": "updateFile", "file": raw])
        _model = StateObject(wrappedValue: model)
        file = TelegramFile(raw)
    }
    private func preview(_ title: String, _ url: String, skip: Bool) -> TelegramLinkPreview {
        TelegramLinkPreview(["url": url, "title": title, "skip_confirmation": skip])!
    }
    var body: some Scene {
        WindowGroup("Synapse · Link Preview QA") {
            VStack(spacing: 20) {
                HStack {
                    VStack {
                        Text("Link thumbnail")
                        TelegramLinkThumbnailView(model: model, file: useMissingFile ? TelegramFile(["id": 778]) : file)
                    }.frame(width: 340, height: 210)
                    VStack { Text("Existing photo"); TelegramPhotoView(model: model, file: file) }.frame(width: 340, height: 210)
                }
                Button(useMissingFile ? "Restore cached thumbnail" : "Switch to uncached thumbnail") { useMissingFile.toggle() }
                TelegramLinkPreviewCard(model: model, preview: preview("Hidden destination", "https://example.com/confirmed", skip: false), isOutgoing: false, openURL: { opens.append($0.absoluteString) })
                TelegramLinkPreviewCard(model: model, preview: preview("Visible destination", "https://example.com/direct", skip: true), isOutgoing: false, openURL: { opens.append($0.absoluteString) })
                TelegramLinkPreviewCard(model: model, preview: preview("Unsupported destination", "custom-app://action", skip: true), isOutgoing: false, openURL: { opens.append($0.absoluteString) })
                Text("Captured opens: \(opens.count)")
                Text(opens.last ?? "No URL opened").font(.caption)
            }.padding(24)
        }.defaultSize(width: 760, height: 610)
    }
}
