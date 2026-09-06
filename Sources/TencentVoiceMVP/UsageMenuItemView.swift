import AppKit

final class UsageMenuItemView: NSView {
    static let preferredHeight: CGFloat = 36
    static let horizontalInset: CGFloat = 14
    static let lineHeight: CGFloat = 18

    let modelTextField: NSTextField
    let usageTextField: NSTextField
    private var storedText: String

    var text: String {
        get { storedText }
        set {
            storedText = newValue
            let lines = newValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            modelTextField.stringValue = String(lines.first ?? "")
            usageTextField.stringValue = lines.count > 1 ? String(lines[1]) : ""
            setFrameSize(NSSize(width: Self.width(for: newValue), height: frame.height))
            invalidateIntrinsicContentSize()
        }
    }

    init(text: String) {
        modelTextField = NSTextField(labelWithString: "")
        usageTextField = NSTextField(labelWithString: "")
        storedText = text
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.width(for: text),
            height: Self.preferredHeight
        ))

        for field in [modelTextField, usageTextField] {
            field.font = NSFont.menuFont(ofSize: 0)
            field.textColor = .disabledControlTextColor
            field.alignment = .left
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }

        NSLayoutConstraint.activate([
            modelTextField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            modelTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            modelTextField.topAnchor.constraint(equalTo: topAnchor),
            modelTextField.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            usageTextField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            usageTextField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            usageTextField.topAnchor.constraint(equalTo: modelTextField.bottomAnchor),
            usageTextField.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            usageTextField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        self.text = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func width(for text: String) -> CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let maxLineWidth = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { NSString(string: String($0)).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return ceil(maxLineWidth) + horizontalInset * 2
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(for: storedText), height: Self.preferredHeight)
    }
}
