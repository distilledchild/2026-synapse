import SwiftUI
import AppKit

final class ComposerTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    private var lastReportedHeight: CGFloat = 0

    func updateHeight() {
        guard let layoutManager, let textContainer, bounds.width > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        let line = layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 14))
        let extraLine = string.hasSuffix("\n") ? line : 0
        let desired = ceil(max(32, min(120, max(line, used + extraLine) + textContainerInset.height * 2)))
        enclosingScrollView?.hasVerticalScroller = desired >= 120
        guard desired != lastReportedHeight else { return }
        lastReportedHeight = desired
        DispatchQueue.main.async { [weak self] in self?.onHeightChange(desired) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateHeight()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        // Let the input method consume Return while composing Korean/CJK text.
        if isReturn && !hasMarkedText() && (modifiers.isEmpty || modifiers == .shift) {
            guard isEditable else { return }
            if modifiers == .shift {
                insertNewline(nil)
            } else if !event.isARepeat {
                onSubmit()
            }
            return
        }
        super.keyDown(with: event)
    }
}

struct MessageComposer: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var onSubmit: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .textColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("Message composer")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSubmit = onSubmit
        editor.onHeightChange = onHeightChange
        editor.isEditable = isEditable
        if editor.string != text && !editor.hasMarkedText() {
            editor.string = text
        }
        editor.updateHeight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageComposer
        init(_ parent: MessageComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ComposerTextView else { return }
            parent.text = editor.string
            editor.updateHeight()
        }
    }
}
