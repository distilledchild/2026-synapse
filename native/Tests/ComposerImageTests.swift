import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct ComposerImageTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }
            checks += 1
            print("PASS: \(label)")
        }
        func key(_ flags: NSEvent.ModifierFlags = [], code: UInt16 = 36, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: repeatKey, keyCode: code)!
        }
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        editor.isRichText = false
        var sends = 0
        editor.onSubmit = { sends += 1 }
        editor.string = "첫 줄"
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: key(.shift))
        check(editor.string == "첫 줄\n" && sends == 0, "Shift+Enter inserts newline without sending")
        editor.insertText("다음 줄 🌍", replacementRange: editor.selectedRange())
        editor.keyDown(with: key())
        check(sends == 1 && editor.string == "첫 줄\n다음 줄 🌍", "Enter sends without appending a newline")
        editor.keyDown(with: key(repeatKey: true))
        check(sends == 1, "held Enter does not repeat the send")
        editor.keyDown(with: key(code: 76))
        check(sends == 2, "keypad Enter sends")
        editor.keyDown(with: key(.shift, code: 76))
        check(editor.string.hasSuffix("\n") && sends == 2, "Shift+keypad Enter inserts newline")
        editor.insertText("붙여넣기\n여러 줄", replacementRange: editor.selectedRange())
        check(editor.string.hasSuffix("붙여넣기\n여러 줄") && sends == 2, "multiline paste never sends")
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        check(editor.hasMarkedText(), "Korean marked text fixture is active")
        editor.keyDown(with: key())
        check(sends == 2, "Return during IME composition never submits")
        editor.unmarkText()
        editor.isEditable = false
        editor.keyDown(with: key())
        check(sends == 2, "disabled editor cannot send")
        var height: CGFloat = 0
        editor.onHeightChange = { height = $0 }
        editor.string = ""
        editor.updateHeight()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(height == 32, "empty composer is one line high")
        editor.string = "첫 줄\n다음 줄\n세 번째 줄"
        editor.updateHeight()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(height > 32 && height < 120, "explicit newlines grow composer to content height")
        editor.string = String(repeating: "긴 메시지 줄\n", count: 20)
        editor.updateHeight()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(height == 120, "long composer stops growing at the scroll limit")
        editor.string = ""
        editor.updateHeight()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(height == 32, "clearing a sent draft restores one line")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synapse-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("sample.png")
        let context = CGContext(data: nil, width: 2400, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.43, green: 0.34, blue: 0.88, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination), "synthetic PNG created")
        func attachment(_ url: URL, mime: String = "image/png") -> MessageAttachment {
            MessageAttachment(id: 1, filename: url.path, mimeType: mime, name: url.lastPathComponent)
        }
        let thumbnail = AttachmentImageLoader.image(for: attachment(imageURL), root: root)
        check(thumbnail?.width == 1400 && thumbnail?.height == 700, "image is decoded into bounded thumbnail with aspect ratio")
        let payloadImage = root.appendingPathComponent("photo.pluginPayloadAttachment")
        try FileManager.default.copyItem(at: imageURL, to: payloadImage)
        let payloadAttachment = MessageAttachment(id: 2, filename: payloadImage.path, mimeType: nil, name: payloadImage.lastPathComponent)
        check(AttachmentImageLoader.image(for: payloadAttachment, root: root) != nil, "link payload image decodes by content without image extension or MIME")
        check(AttachmentImageLoader.image(for: attachment(imageURL), root: root.appendingPathComponent("other")) == nil, "file outside allowed attachment directory is blocked")
        check(AttachmentImageLoader.image(for: attachment(root.appendingPathComponent("missing.png")), root: root) == nil, "missing download is handled without a crash")
        let corrupt = root.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        check(AttachmentImageLoader.image(for: attachment(corrupt), root: root) == nil, "corrupt image is handled without a crash")
        let link = root.appendingPathComponent("outside.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        check(AttachmentImageLoader.image(for: attachment(link), root: root) == nil, "symlink escaping attachment directory is blocked")
        check(AttachmentImageLoader.image(for: attachment(root), root: root) == nil, "directory is not decoded as an image")
        print("SUCCESS: \(checks) composer/image checks; no real messages or attachments accessed")
    }
}
