import AppKit

/// A Spotlight-style text box that floats above the buddy. It can take typing
/// without activating the app or stealing focus from the window behind it.
final class ChatBox: NSPanel, NSTextFieldDelegate {
    private let field = NSTextField()
    var onSubmit: ((String) -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        field.frame = NSRect(x: 12, y: 9, width: 256, height: 22)
        field.placeholderString = "Say something…  (esc to close)"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        bg.addSubview(field)
        contentView = bg
    }

    func show(above rect: NSRect, placeholder: String) {
        field.placeholderString = placeholder
        setFrameOrigin(NSPoint(x: rect.midX - frame.width / 2, y: rect.maxY + 8))
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            field.stringValue = ""
            orderOut(nil)
            if !text.isEmpty { onSubmit?(text) }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            orderOut(nil)
            return true
        }
        return false
    }
}
