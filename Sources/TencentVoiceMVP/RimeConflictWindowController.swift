import AppKit
import RimeSyncCore

@MainActor
final class RimeConflictWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let reviewCoordinator: RimeReviewSyncCoordinator
    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "请选择一个冲突文件")
    private let variantsTextView = NSTextView()
    private let localTextView = NSTextView()
    private let sharedTextView = NSTextView()
    private let mergeTextView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let keepLocalButton = NSButton(title: "保留当前账户版本", target: nil, action: nil)
    private let keepSharedButton = NSButton(title: "采用共享版本", target: nil, action: nil)
    private let applyMergeButton = NSButton(title: "应用人工合并", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private var previews: [RimeConflictPreview] = []
    var onConflictsChanged: (() -> Void)?

    init(reviewCoordinator: RimeReviewSyncCoordinator) {
        self.reviewCoordinator = reviewCoordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_160, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "处理 Rime 配置冲突"
        window.minSize = NSSize(width: 920, height: 620)
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
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        tableColumn.title = "待处理文件"
        tableColumn.width = 260
        tableView.addTableColumn(tableColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        configureTextView(variantsTextView, editable: false)
        configureTextView(localTextView, editable: false)
        configureTextView(sharedTextView, editable: false)
        configureTextView(mergeTextView, editable: true)

        summaryLabel.font = .boldSystemFont(ofSize: 13)
        summaryLabel.textColor = .labelColor
        summaryLabel.lineBreakMode = .byWordWrapping

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byWordWrapping

        for button in [keepLocalButton, keepSharedButton, applyMergeButton, refreshButton] {
            button.target = self
            button.bezelStyle = .rounded
        }
        keepLocalButton.action = #selector(keepLocalPressed)
        keepSharedButton.action = #selector(keepSharedPressed)
        applyMergeButton.action = #selector(applyMergePressed)
        refreshButton.action = #selector(refreshPressed)

        let left = NSStackView(views: [
            NSTextField(labelWithString: "未解决冲突"),
            tableScroll
        ])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false

        let variantBox = labeledScrollView(title: "涉及节点版本", textView: variantsTextView)
        let localBox = labeledScrollView(title: "当前账户版本", textView: localTextView)
        let sharedBox = labeledScrollView(title: "共享版本", textView: sharedTextView)
        let mergeBox = labeledScrollView(title: "可编辑的合并结果", textView: mergeTextView)
        let sourceComparison = NSStackView(views: [localBox, sharedBox])
        sourceComparison.orientation = .horizontal
        sourceComparison.distribution = .fillEqually
        sourceComparison.spacing = 8
        sourceComparison.translatesAutoresizingMaskIntoConstraints = false
        let comparison = NSStackView(views: [variantBox, sourceComparison, mergeBox])
        comparison.orientation = .vertical
        comparison.alignment = .leading
        comparison.spacing = 8
        comparison.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [
            keepLocalButton,
            keepSharedButton,
            applyMergeButton,
            NSView(),
            refreshButton
        ])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        let right = NSStackView(views: [summaryLabel, comparison, statusLabel, actions])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.translatesAutoresizingMaskIntoConstraints = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(split)

        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            split.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            split.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            left.widthAnchor.constraint(equalToConstant: 280),
            tableScroll.widthAnchor.constraint(equalTo: left.widthAnchor),
            comparison.widthAnchor.constraint(equalTo: right.widthAnchor),
            sourceComparison.widthAnchor.constraint(equalTo: comparison.widthAnchor),
            sourceComparison.heightAnchor.constraint(equalToConstant: 130),
            localBox.widthAnchor.constraint(equalTo: sharedBox.widthAnchor),
            variantBox.widthAnchor.constraint(equalTo: comparison.widthAnchor),
            mergeBox.widthAnchor.constraint(equalTo: comparison.widthAnchor),
            variantBox.heightAnchor.constraint(equalToConstant: 130),
            mergeBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            actions.widthAnchor.constraint(equalTo: right.widthAnchor)
        ])
    }

    private func configureTextView(_ textView: NSTextView, editable: Bool) {
        textView.isEditable = editable
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isRichText = false
        textView.usesFindPanel = true
        textView.autoresizingMask = [.width]
    }

    private func labeledScrollView(title: String, textView: NSTextView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
        return stack
    }

    @objc private func refreshPressed() {
        refresh()
    }

    private func refresh() {
        defer { onConflictsChanged?() }
        do {
            previews = try reviewCoordinator.configurationConflictPreviews()
            tableView.reloadData()
            if previews.isEmpty {
                clearSelection(message: "当前没有未解决冲突。")
            } else {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                show(preview: previews[0])
                statusLabel.stringValue = "存在 \(previews.count) 个未解决冲突；处理前会重新核对版本。"
            }
        } catch {
            previews = []
            tableView.reloadData()
            clearSelection(message: "读取冲突失败：\(error.localizedDescription)")
        }
    }

    private func clearSelection(message: String) {
        summaryLabel.stringValue = "请选择一个冲突文件"
        variantsTextView.string = ""
        localTextView.string = ""
        sharedTextView.string = ""
        mergeTextView.string = ""
        statusLabel.stringValue = message
        [keepLocalButton, keepSharedButton, applyMergeButton].forEach { $0.isEnabled = false }
    }

    private func show(preview: RimeConflictPreview) {
        summaryLabel.stringValue = "\(preview.relativePath) · \(preview.reason.displayName)"
        let variantText = preview.variants.map { variant in
            let header = "[\(variant.nodeID)] \(variant.record.state.rawValue), \(variant.record.byteCount) bytes"
            guard let text = variant.text else { return header + "\n（二进制或内容不可按文本显示）" }
            return header + "\n" + text
        }.joined(separator: "\n\n")
        variantsTextView.string = variantText
        localTextView.string = preview.localText ?? "（当前账户没有可读取的文本版本）"
        sharedTextView.string = preview.sharedText ?? "（共享版本没有可读取的文本内容）"
        mergeTextView.string = preview.suggestedMerge ?? preview.localText ?? preview.sharedText ?? ""
        let editable = preview.localText != nil && preview.sharedText != nil
        mergeTextView.isEditable = editable
        keepLocalButton.isEnabled = preview.localRecord != nil
        keepSharedButton.isEnabled = preview.sharedRecord != nil
        applyMergeButton.isEnabled = editable
    }

    private func selectedPreview() -> RimeConflictPreview? {
        guard previews.indices.contains(tableView.selectedRow) else { return nil }
        return previews[tableView.selectedRow]
    }

    private func apply(_ resolution: RimeConflictResolution, label: String) {
        guard let preview = selectedPreview() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认处理 \(preview.relativePath)？"
        alert.informativeText = "\(label)将覆盖当前账户、本地节点副本及相关基线；原状态已备份。其他文件和实时用户词库不会被恢复或覆盖。"
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let report = try reviewCoordinator.resolveConfigurationConflict(
                path: preview.relativePath,
                resolution: resolution,
                expectedVersion: preview.versionToken
            )
            if report.reloadSucceeded {
                statusLabel.stringValue = "已保存并发布 \(preview.relativePath)，Rime 已重载。"
            } else {
                statusLabel.stringValue = "配置已保存，生效失败：\(report.reloadError ?? "未知重载错误")；请重试。"
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
