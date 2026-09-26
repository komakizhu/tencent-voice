import AppKit
import RimeSyncCore

@MainActor
final class RimeConflictWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let reviewCoordinator: RimeReviewSyncCoordinator
    private let tableView = NSTableView()
    private let conflictListTitle = NSTextField(labelWithString: "待处理冲突")
    private let selectedFileLabel = NSTextField(labelWithString: "请选择一个文件")
    private let selectedReasonLabel = NSTextField(labelWithString: "")
    private let instructionLabel = NSTextField(
        wrappingLabelWithString: "请选择要保留的版本。需要同时保留双方内容时，再展开详细内容进行手动合并。"
    )
    private let localComparisonLabel = NSTextField(labelWithString: "")
    private let sharedComparisonLabel = NSTextField(labelWithString: "")
    private let localDescriptionLabel = NSTextField(labelWithString: "保留这台 Mac 当前的 Rime 配置")
    private let sharedDescriptionLabel = NSTextField(labelWithString: "使用共享目录中的配置")
    private let detailsToggleButton = NSButton(
        checkboxWithTitle: "查看详细内容（代码预览）",
        target: nil,
        action: nil
    )
    private let detailsContainer = NSView()
    private let localDiffTextView = NSTextView()
    private let sharedDiffTextView = NSTextView()
    private let localDiffScrollView = NSScrollView()
    private let sharedDiffScrollView = NSScrollView()
    private let variantsTextView = NSTextView()
    private let localTextView = NSTextView()
    private let sharedTextView = NSTextView()
    private let mergeTextView = NSTextView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let keepLocalButton = NSButton(title: "保留当前账户版本", target: nil, action: nil)
    private let keepSharedButton = NSButton(title: "采用共享版本", target: nil, action: nil)
    private let applyMergeButton = NSButton(title: "应用手动合并", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private var previews: [RimeConflictPreview] = []
    private var detailsVisible = false
    var onConflictsChanged: (() -> Void)?

    init(reviewCoordinator: RimeReviewSyncCoordinator) {
        self.reviewCoordinator = reviewCoordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "处理 Rime 配置冲突"
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func begin() {
        refresh()
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }

        configureTable()
        configureDiffTextView(localDiffTextView)
        configureDiffTextView(sharedDiffTextView)
        configureTextView(variantsTextView, editable: false)
        configureTextView(localTextView, editable: false)
        configureTextView(sharedTextView, editable: false)
        configureTextView(mergeTextView, editable: true)
        configureLabels()
        configureButtons()

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        let left = NSStackView(views: [conflictListTitle, tableScroll])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false

        let rightScroll = NSScrollView()
        rightScroll.hasVerticalScroller = true
        rightScroll.autohidesScrollers = true
        rightScroll.borderType = .noBorder
        rightScroll.translatesAutoresizingMaskIntoConstraints = false

        let rightDocument = NSView()
        rightDocument.translatesAutoresizingMaskIntoConstraints = false
        rightScroll.documentView = rightDocument

        let choices = NSStackView(views: [
            choiceCard(
                button: keepLocalButton,
                comparisonLabel: localComparisonLabel,
                descriptionLabel: localDescriptionLabel,
                previewScrollView: localDiffScrollView,
                previewTextView: localDiffTextView
            ),
            choiceCard(
                button: keepSharedButton,
                comparisonLabel: sharedComparisonLabel,
                descriptionLabel: sharedDescriptionLabel,
                previewScrollView: sharedDiffScrollView,
                previewTextView: sharedDiffTextView
            )
        ])
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        choices.spacing = 12
        choices.translatesAutoresizingMaskIntoConstraints = false
        choices.setContentHuggingPriority(.required, for: .vertical)
        choices.setContentCompressionResistancePriority(.required, for: .vertical)

        let detailsTitle = NSTextField(labelWithString: "详细内容")
        detailsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let detailsHint = NSTextField(
            wrappingLabelWithString: "普通处理不需要阅读代码。只有想保留双方修改时，才需要编辑合并结果。"
        )
        detailsHint.font = .systemFont(ofSize: 11)
        detailsHint.textColor = .secondaryLabelColor

        let variantBox = labeledScrollView(title: "各节点版本摘要", textView: variantsTextView, height: 110)
        let localBox = labeledScrollView(title: "当前账户内容", textView: localTextView, height: 150)
        let sharedBox = labeledScrollView(title: "共享内容", textView: sharedTextView, height: 150)
        let mergeBox = labeledScrollView(title: "可编辑的合并结果", textView: mergeTextView, height: 210)
        let sourceComparison = NSStackView(views: [localBox, sharedBox])
        sourceComparison.orientation = .horizontal
        sourceComparison.distribution = .fillEqually
        sourceComparison.spacing = 10
        sourceComparison.translatesAutoresizingMaskIntoConstraints = false

        let detailsStack = NSStackView(
            views: [detailsTitle, detailsHint, variantBox, sourceComparison, mergeBox, applyMergeButton]
        )
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 8
        detailsStack.detachesHiddenViews = true
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        detailsContainer.addSubview(detailsStack)
        detailsContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailsStack.leadingAnchor.constraint(equalTo: detailsContainer.leadingAnchor),
            detailsStack.trailingAnchor.constraint(equalTo: detailsContainer.trailingAnchor),
            detailsStack.topAnchor.constraint(equalTo: detailsContainer.topAnchor),
            detailsStack.bottomAnchor.constraint(equalTo: detailsContainer.bottomAnchor),
            sourceComparison.widthAnchor.constraint(equalTo: detailsStack.widthAnchor)
        ])

        let sectionTitle = NSTextField(labelWithString: "选择处理方式")
        sectionTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let actions = NSStackView(views: [NSView(), refreshButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [
            selectedFileLabel,
            selectedReasonLabel,
            instructionLabel,
            sectionTitle,
            choices,
            detailsToggleButton,
            detailsContainer,
            statusLabel,
            actions
        ])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 10
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightDocument.addSubview(rightStack)

        NSLayoutConstraint.activate([
            rightDocument.leadingAnchor.constraint(equalTo: rightScroll.contentView.leadingAnchor),
            rightDocument.trailingAnchor.constraint(equalTo: rightScroll.contentView.trailingAnchor),
            rightDocument.topAnchor.constraint(equalTo: rightScroll.contentView.topAnchor),
            rightDocument.bottomAnchor.constraint(equalTo: rightScroll.contentView.bottomAnchor),
            rightDocument.widthAnchor.constraint(equalTo: rightScroll.contentView.widthAnchor),
            rightStack.leadingAnchor.constraint(equalTo: rightDocument.leadingAnchor, constant: 20),
            rightStack.trailingAnchor.constraint(equalTo: rightDocument.trailingAnchor, constant: -20),
            rightStack.topAnchor.constraint(equalTo: rightDocument.topAnchor, constant: 20),
            rightStack.bottomAnchor.constraint(equalTo: rightDocument.bottomAnchor, constant: -20),
            tableScroll.widthAnchor.constraint(equalTo: left.widthAnchor),
            choices.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: rightStack.widthAnchor),
            detailsContainer.widthAnchor.constraint(equalTo: rightStack.widthAnchor)
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(rightScroll)
        split.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(split)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            split.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            left.widthAnchor.constraint(equalToConstant: 235),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 205)
        ])

        detailsContainer.isHidden = true
    }

    private func configureTable() {
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        tableColumn.title = "待处理文件"
        tableColumn.width = 225
        tableView.addTableColumn(tableColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
    }

    private func configureLabels() {
        conflictListTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        selectedFileLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        selectedFileLabel.lineBreakMode = .byTruncatingMiddle

        selectedReasonLabel.font = .systemFont(ofSize: 12)
        selectedReasonLabel.textColor = .secondaryLabelColor

        for label in [
            instructionLabel,
            statusLabel,
            localComparisonLabel,
            sharedComparisonLabel,
            localDescriptionLabel,
            sharedDescriptionLabel
        ] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
        }
        instructionLabel.font = .systemFont(ofSize: 13)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        localDescriptionLabel.font = .systemFont(ofSize: 11)
        sharedDescriptionLabel.font = .systemFont(ofSize: 11)
        localDescriptionLabel.textColor = .secondaryLabelColor
        sharedDescriptionLabel.textColor = .secondaryLabelColor
        localComparisonLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        sharedComparisonLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    }

    private func configureButtons() {
        for button in [keepLocalButton, keepSharedButton, applyMergeButton, refreshButton] {
            button.target = self
            button.bezelStyle = .rounded
            button.controlSize = .large
        }
        keepLocalButton.action = #selector(keepLocalPressed)
        keepSharedButton.action = #selector(keepSharedPressed)
        applyMergeButton.action = #selector(applyMergePressed)
        refreshButton.action = #selector(refreshPressed)
        detailsToggleButton.target = self
        detailsToggleButton.action = #selector(detailsTogglePressed)
        detailsToggleButton.controlSize = .small
        detailsToggleButton.font = .systemFont(ofSize: 11)
        detailsToggleButton.toolTip = "展开或收起版本内容与手动合并区域"
        keepLocalButton.toolTip = "使用这台 Mac 当前账户中的 Rime 配置"
        keepSharedButton.toolTip = "使用共享同步目录中的 Rime 配置"
        applyMergeButton.toolTip = "保存下方编辑后的合并结果"
    }

    private func configureTextView(_ textView: NSTextView, editable: Bool) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainerInset = NSSize(width: 0, height: 6)
    }

    private func configureDiffTextView(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .textColor
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 8
        textView.textContainerInset = NSSize(width: 0, height: 6)
    }

    private func choiceCard(
        button: NSButton,
        comparisonLabel: NSTextField,
        descriptionLabel: NSTextField,
        previewScrollView: NSScrollView,
        previewTextView: NSTextView
    ) -> NSView {
        previewScrollView.documentView = previewTextView
        previewScrollView.hasVerticalScroller = true
        previewScrollView.hasHorizontalScroller = false
        previewScrollView.autohidesScrollers = true
        previewScrollView.borderType = .bezelBorder
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        previewScrollView.isHidden = true

        let stack = NSStackView(views: [comparisonLabel, previewScrollView, button, descriptionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            previewScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewScrollView.heightAnchor.constraint(equalToConstant: 220)
        ])

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 12, height: 10)
        box.contentView = stack
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)
        return box
    }

    private func labeledScrollView(title: String, textView: NSTextView, height: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [label, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: height)
        ])
        return stack
    }

    @objc private func refreshPressed() {
        refresh()
    }

    @objc private func detailsTogglePressed() {
        detailsVisible.toggle()
        detailsContainer.isHidden = !detailsVisible
        detailsToggleButton.title = detailsVisible ? "收起详细内容" : "查看详细内容（代码预览）"
        window?.recalculateKeyViewLoop()
    }

    private func refresh() {
        defer { onConflictsChanged?() }
        do {
            previews = try reviewCoordinator.configurationConflictPreviews()
            tableView.reloadData()
            conflictListTitle.stringValue = previews.isEmpty
                ? "没有待处理冲突"
                : "待处理冲突（\(previews.count)）"
            if previews.isEmpty {
                clearSelection(message: "所有 Rime 配置都已处理。")
            } else {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                show(preview: previews[0])
                statusLabel.stringValue = "处理前会再次检查文件是否变化，原状态会自动备份。"
            }
        } catch {
            previews = []
            tableView.reloadData()
            conflictListTitle.stringValue = "无法读取冲突"
            clearSelection(message: "读取失败：\(error.localizedDescription)")
        }
    }

    private func clearSelection(message: String) {
        selectedFileLabel.stringValue = "没有选择文件"
        selectedFileLabel.toolTip = nil
        selectedReasonLabel.stringValue = ""
        localComparisonLabel.stringValue = "当前账户版本不可用"
        sharedComparisonLabel.stringValue = "共享版本不可用"
        localComparisonLabel.textColor = .systemOrange
        sharedComparisonLabel.textColor = .systemOrange
        localDiffTextView.string = ""
        sharedDiffTextView.string = ""
        localDiffScrollView.isHidden = true
        sharedDiffScrollView.isHidden = true
        localDescriptionLabel.stringValue = "没有可用的当前账户版本"
        sharedDescriptionLabel.stringValue = "没有可用的共享版本"
        variantsTextView.string = ""
        localTextView.string = ""
        sharedTextView.string = ""
        mergeTextView.string = ""
        statusLabel.stringValue = message
        detailsToggleButton.isEnabled = false
        detailsContainer.isHidden = true
        detailsVisible = false
        detailsToggleButton.title = "查看详细内容（代码预览）"
        [keepLocalButton, keepSharedButton, applyMergeButton].forEach { $0.isEnabled = false }
    }

    private func show(preview: RimeConflictPreview) {
        selectedFileLabel.stringValue = preview.relativePath
        selectedFileLabel.toolTip = preview.relativePath
        selectedReasonLabel.stringValue = preview.reason.displayName

        let comparison = versionComparison(for: preview)
        let nodeCount = preview.variants.count
        instructionLabel.stringValue = comparison.hasContentConflict
            ? "下面会直接标出两边不同的内容。红色标记表示该行与另一版本不一致，请选择要保留的版本。"
            : nodeCount > 1
                ? "当前两边内容相同，不显示代码预览。选择任一版本即可确认这条历史记录。"
                : "当前两边内容相同，不显示代码预览。选择一个版本即可确认这条记录。"

        localDescriptionLabel.stringValue = preview.localRecord == nil
            ? "当前账户版本不可用"
            : "保留这台 Mac 当前的 Rime 配置"
        sharedDescriptionLabel.stringValue = preview.sharedRecord == nil
            ? "共享版本不可用"
            : "使用共享目录中的 Rime 配置"
        localComparisonLabel.stringValue = comparison.local.title
        localComparisonLabel.textColor = comparison.local.color
        sharedComparisonLabel.stringValue = comparison.shared.title
        sharedComparisonLabel.textColor = comparison.shared.color
        updateDiffPreview(
            textView: localDiffTextView,
            scrollView: localDiffScrollView,
            text: preview.localText,
            counterpart: preview.sharedText,
            isVisible: comparison.hasContentConflict
        )
        updateDiffPreview(
            textView: sharedDiffTextView,
            scrollView: sharedDiffScrollView,
            text: preview.sharedText,
            counterpart: preview.localText,
            isVisible: comparison.hasContentConflict
        )

        let variantText = preview.variants.map { variant in
            let header = "［\(variant.nodeID)］\(variant.record.state.rawValue)，\(variant.record.byteCount) 字节"
            guard let text = variant.text else { return header + "\n（无法按文本预览）" }
            return header + "\n" + text
        }.joined(separator: "\n\n")
        variantsTextView.string = variantText
        localTextView.string = preview.localText ?? "（当前账户没有可读取的文本内容）"
        sharedTextView.string = preview.sharedText ?? "（共享版本没有可读取的文本内容）"
        mergeTextView.string = preview.suggestedMerge ?? preview.localText ?? preview.sharedText ?? ""

        let hasDetails = !preview.variants.isEmpty || preview.localText != nil || preview.sharedText != nil
        let editable = preview.localText != nil && preview.sharedText != nil
        detailsToggleButton.isEnabled = hasDetails
        mergeTextView.isEditable = editable
        keepLocalButton.isEnabled = preview.localRecord != nil
        keepSharedButton.isEnabled = preview.sharedRecord != nil
        applyMergeButton.isEnabled = editable
    }

    private struct VersionComparisonState {
        let title: String
        let color: NSColor
    }

    private struct VersionComparison {
        let local: VersionComparisonState
        let shared: VersionComparisonState
        let hasContentConflict: Bool
    }

    private func versionComparison(for preview: RimeConflictPreview) -> VersionComparison {
        guard let localRecord = preview.localRecord, let sharedRecord = preview.sharedRecord else {
            let local = preview.localRecord == nil
                ? VersionComparisonState(title: "当前版本不可用", color: .systemOrange)
                : VersionComparisonState(title: "当前版本可用", color: .labelColor)
            let shared = preview.sharedRecord == nil
                ? VersionComparisonState(title: "共享版本不可用", color: .systemOrange)
                : VersionComparisonState(title: "共享版本可用", color: .labelColor)
            return VersionComparison(local: local, shared: shared, hasContentConflict: false)
        }

        guard localRecord.contentIdentity != sharedRecord.contentIdentity else {
            let same = VersionComparisonState(title: "内容相同，无需比较", color: .secondaryLabelColor)
            return VersionComparison(local: same, shared: same, hasContentConflict: false)
        }

        let conflict = VersionComparisonState(title: "发现内容差异（已标出）", color: .systemRed)
        return VersionComparison(local: conflict, shared: conflict, hasContentConflict: true)
    }

    private func updateDiffPreview(
        textView: NSTextView,
        scrollView: NSScrollView,
        text: String?,
        counterpart: String?,
        isVisible: Bool
    ) {
        scrollView.isHidden = !isVisible
        guard isVisible else {
            textView.string = ""
            return
        }
        guard let text, let counterpart else {
            let unavailable = NSAttributedString(
                string: "存在差异，但当前内容无法按文本预览。",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            textView.textStorage?.setAttributedString(unavailable)
            return
        }
        textView.textStorage?.setAttributedString(
            highlightedDiffText(text: text, counterpart: counterpart)
        )
    }

    private func highlightedDiffText(text: String, counterpart: String) -> NSAttributedString {
        let lines = text.components(separatedBy: "\n")
        let counterpartLines = counterpart.components(separatedBy: "\n")
        let changedLines = differingLineIndexes(lines, counterpartLines)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        var location = 0
        for index in lines.indices {
            let lineLength = (lines[index] as NSString).length
            if changedLines.contains(index), lineLength > 0 {
                result.addAttributes(
                    [
                        .backgroundColor: NSColor.systemRed.withAlphaComponent(0.18),
                        .foregroundColor: NSColor.labelColor
                    ],
                    range: NSRange(location: location, length: lineLength)
                )
            }
            location += lineLength
            if index < lines.count - 1 { location += 1 }
        }
        return result
    }

    private func differingLineIndexes(_ lines: [String], _ counterpartLines: [String]) -> Set<Int> {
        Set(lines.difference(from: counterpartLines).compactMap { change in
            guard case let .insert(offset, _, _) = change else { return nil }
            return offset
        })
    }

    private func selectedPreview() -> RimeConflictPreview? {
        guard previews.indices.contains(tableView.selectedRow) else { return nil }
        return previews[tableView.selectedRow]
    }

    private func apply(_ resolution: RimeConflictResolution, label: String) {
        guard let preview = selectedPreview() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认处理这个文件？"
        alert.informativeText = "将对“\(preview.relativePath)”\(label)。应用前会重新检查版本，原状态会自动备份。"
        alert.addButton(withTitle: "确认处理")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let report = try reviewCoordinator.resolveConfigurationConflict(
                path: preview.relativePath,
                resolution: resolution,
                expectedVersion: preview.versionToken
            )
            if report.reloadSucceeded {
                statusLabel.stringValue = "已处理 \(preview.relativePath)，Rime 已重新加载。"
            } else {
                statusLabel.stringValue = "配置已保存，但 Rime 未能重新加载：\(report.reloadError ?? "未知原因")。"
            }
            refresh()
        } catch {
            statusLabel.stringValue = error.localizedDescription
            refresh()
        }
    }

    @objc private func keepLocalPressed() {
        apply(.keepLocal, label: "保留当前账户版本")
    }

    @objc private func keepSharedPressed() {
        apply(.keepShared, label: "采用共享版本")
    }

    @objc private func applyMergePressed() {
        apply(.merge(mergeTextView.string), label: "应用编辑后的合并结果")
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        previews.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard previews.indices.contains(row) else { return nil }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.stringValue = "\(previews[row].relativePath)\n\(previews[row].reason.displayName)"
        field.maximumNumberOfLines = 2
        field.font = .systemFont(ofSize: 11)
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let preview = selectedPreview() else {
            clearSelection(message: "请选择一个冲突文件")
            return
        }
        show(preview: preview)
    }
}
