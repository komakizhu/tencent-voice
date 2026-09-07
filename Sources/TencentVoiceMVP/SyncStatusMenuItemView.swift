import AppKit

final class SyncStatusMenuItemView: NSView {
    static let horizontalInset = UsageMenuItemView.horizontalInset
    static let lineHeight = UsageMenuItemView.lineHeight

    let textField: NSTextField
    private var storedText: String
    private var contentWidth: CGFloat

    var text: String {
        get { storedText }
        set {
            storedText = newValue
            textField.stringValue = newValue
            updateFrameHeight()
        }
    }

    init(text: String, width: CGFloat) {
        textField = NSTextField(labelWithString: text)
        storedText = text
        contentWidth = max(width, Self.horizontalInset * 2 + 1)
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: Self.height(for: text, width: contentWidth)
        ))

        textField.font = NSFont.menuFont(ofSize: 0)
        textField.textColor = .disabledControlTextColor
        textField.alignment = .left
        textField.usesSingleLineMode = false
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        updateFrameHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(width: CGFloat) {
        contentWidth = max(width, Self.horizontalInset * 2 + 1)
        updateFrameHeight()
    }

    override func layout() {
        super.layout()
        textField.frame = NSRect(
            x: Self.horizontalInset,
            y: 0,
            width: max(1, bounds.width - Self.horizontalInset * 2),
            height: bounds.height
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: contentWidth, height: Self.height(for: storedText, width: contentWidth))
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let contentWidth = max(1, width - horizontalInset * 2)
        let bounds = NSString(string: text).boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(lineHeight, ceil(bounds.height))
    }

    private func updateFrameHeight() {
        setFrameSize(NSSize(width: contentWidth, height: Self.height(for: storedText, width: contentWidth)))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}
