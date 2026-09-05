import AppKit
import RimeSyncCore
import UniformTypeIdentifiers

@MainActor
final class ManualRimeEntryForm: NSView {
    let wordField: NSTextField
    let codeField: NSTextField
    let frequencyField: NSTextField
    private let labels: [NSTextField]

    override init(frame frameRect: NSRect) {
        wordField = NSTextField()
        codeField = NSTextField()
        frequencyField = NSTextField()
        labels = ["词条", "全拼编码", "频率"].map { labelText in
            let label = NSTextField(labelWithString: labelText)
            label.alignment = .right
            return label
        }
        super.init(frame: frameRect)

        translatesAutoresizingMaskIntoConstraints = true
        let fields = [wordField, codeField, frequencyField]
        for (index, field) in fields.enumerated() {
            field.placeholderString = index == 0
                ? "词条（必填）"
                : index == 1
                    ? "全拼编码（必填）"
                    : "频率（可选，默认 1）"
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
            field.drawsBackground = true
            field.translatesAutoresizingMaskIntoConstraints = true
            field.autoresizingMask = [.width]

            let label = labels[index]
            label.translatesAutoresizingMaskIntoConstraints = true
            label.autoresizingMask = [.maxXMargin]
            addSubview(label)
            addSubview(field)
        }
        layoutFields()
    }

    override func layout() {
        super.layout()
        layoutFields()
    }

    private func layoutFields() {
        let fields = [wordField, codeField, frequencyField]
        let rowHeight: CGFloat = 24
        let rowSpacing: CGFloat = 6
        let labelWidth: CGFloat = 66
        let fieldX = labelWidth + 8
        let totalHeight = CGFloat(fields.count) * rowHeight + CGFloat(fields.count - 1) * rowSpacing
        let bottomInset = max(8, (bounds.height - totalHeight) / 2)

        for (index, field) in fields.enumerated() {
            let y = bottomInset + CGFloat(fields.count - 1 - index) * (rowHeight + rowSpacing)
            labels[index].frame = NSRect(x: 0, y: y, width: labelWidth, height: rowHeight)
            field.frame = NSRect(x: fieldX, y: y, width: max(100, bounds.width - fieldX), height: rowHeight)
        }
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 430, height: 112))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class RimeFilterSliderView: NSView {
    let slider: NSSlider
    let tickLabels: [NSTextField]

    init(title: String, tickTitles: [String], slider: NSSlider) {
        precondition(tickTitles.count == 5, "Rime filter sliders must have five discrete values")
        self.slider = slider
        self.tickLabels = tickTitles.map { title in
            let label = NSTextField(labelWithString: title)
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 9)
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        let tickRow = NSStackView(views: tickLabels)
        tickRow.orientation = .horizontal
        tickRow.alignment = .centerY
        tickRow.distribution = .fillEqually
        tickRow.spacing = 0

        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        let control = NSStackView(views: [tickRow, slider])
        control.orientation = .vertical
        control.alignment = .centerX
        control.spacing = 1
        control.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [titleLabel, control])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 58),
            tickRow.widthAnchor.constraint(equalTo: slider.widthAnchor),
            tickRow.heightAnchor.constraint(equalToConstant: 14),
            slider.widthAnchor.constraint(equalToConstant: 210),
            slider.heightAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    var tickTitles: [String] { tickLabels.map(\.stringValue) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class RimeAuditTableView: NSTableView {
    var onContextMenuRow: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return nil }
        onContextMenuRow?(row)
        return super.menu(for: event)
    }
}

@MainActor
final class RimeAuditCheckboxCell: NSTableCellView {
    let checkbox: NSButton

    override init(frame frameRect: NSRect) {
        checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        super.init(frame: frameRect)

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.alignment = .center
        checkbox.toolTip = "选择词条"
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 20),
            checkbox.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class RimeDictionaryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let reviewCoordinator: RimeReviewSyncCoordinator
    private let tableView = RimeAuditTableView()
    private let selectAllButton = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let contextMenu = NSMenu(title: "Rime 词条操作")
    private let searchField = NSSearchField()
    private let viewPopup = NSPopUpButton()
    private let commitSlider = NSSlider()
    private let heatSlider = NSSlider()
    private let activitySlider = NSSlider()
    private let statusLabel = NSTextField(labelWithString: "尚未读取快照")
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let reviewButton = NSButton(title: "重新读取", target: nil, action: nil)
    private let exportButton = NSPopUpButton(title: "导出", target: nil, action: nil)
    private let importProposalButton = NSButton(title: "导入 AI 提案…", target: nil, action: nil)
    private let applyProposalButton = NSButton(title: "应用 AI 提案", target: nil, action: nil)
    private let addButton = NSButton(title: "手动添加词条…", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复备份…", target: nil, action: nil)
    private let cellIdentifier = NSUserInterfaceItemIdentifier("RimeAuditCell")

    private var batch: RimeAuditBatch?
    private var proposalsByEntryID: [String: RimeAuditProposal] = [:]
    private var filteredEntries: [RimeAuditEntry] = []
    private var cachedFilterQuery: RimeAuditQuery?
    private var cachedFilterResult: RimeAuditFilterResult?
    private var selectedIDs = Set<String>()
    private var isWorking = false
    private var lastSyncDescription = "上次同步：未知"

    private enum PreferenceKey {
        static let view = "rime.audit.view"
        static let commit = "rime.audit.commit-band"
        static let heat = "rime.audit.heat-band"
        static let activity = "rime.audit.activity-band"
        static let search = "rime.audit.search"
        static let sort = "rime.audit.sort"
        static let ascending = "rime.audit.ascending"
    }

    init(reviewCoordinator: RimeReviewSyncCoordinator) {
        self.reviewCoordinator = reviewCoordinator
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Rime 词库维护"
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildView()
        restorePreferences()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func begin() { loadAudit(rebuild: false) }

    func reloadFromStoredSnapshot() { loadAudit(rebuild: false) }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        searchField.placeholderString = "搜索词条或编码"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)

        for view in RimeAuditView.allCases {
            viewPopup.addItem(withTitle: view.displayName)
            viewPopup.lastItem?.representedObject = view.rawValue
        }
        viewPopup.target = self
        viewPopup.action = #selector(filterChanged)
        viewPopup.toolTip = "切换词库维护视图"

        configureExportMenu()
        searchField.toolTip = "按词条或编码筛选当前快照"
        reviewButton.toolTip = "只读取上次同步保存的快照，不执行备份或同步"

        configureSlider(commitSlider, action: #selector(commitBandChanged))
        configureSlider(heatSlider, action: #selector(heatBandChanged))
        configureSlider(activitySlider, action: #selector(activityBandChanged))
        commitSlider.toolTip = "累计次数：全部、≥3、≥10、≥30、≥100"
        heatSlider.toolTip = "有效热度：全部、前 50%、前 25%、前 10%、前 1%"
        activitySlider.toolTip = "最近活动：全部、近一年、近半年、近一月、近一周"

        let firstRow = NSStackView(views: [searchField, labeled("视图", viewPopup), NSView(), reviewButton, exportButton])
        firstRow.orientation = .horizontal
        firstRow.alignment = .centerY
        firstRow.spacing = 10
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        viewPopup.setContentHuggingPriority(.required, for: .horizontal)
        exportButton.setContentHuggingPriority(.required, for: .horizontal)
        reviewButton.target = self
        reviewButton.action = #selector(reviewPressed)

        let filters = NSStackView(views: [
            RimeFilterSliderView(title: "累计次数", tickTitles: ["不限", "≥3", "≥10", "≥30", "≥100"], slider: commitSlider),
            RimeFilterSliderView(title: "有效热度", tickTitles: ["不限", "前50%", "前25%", "前10%", "前1%"], slider: heatSlider),
            RimeFilterSliderView(title: "最近活动", tickTitles: ["不限", "1年", "半年", "1月", "1周"], slider: activitySlider),
            thresholdLabel
        ])
        filters.orientation = .horizontal
        filters.alignment = .centerY
        filters.spacing = 16
        thresholdLabel.textColor = .secondaryLabelColor
        thresholdLabel.font = .systemFont(ofSize: 11)

        let columns: [(String, String, CGFloat)] = [
            ("select", "", 36),
            ("text", "词条", 220),
            ("code", "编码", 190),
            ("commit", "最大 c", 76),
            ("heat", "有效热度", 105),
            ("source", "来源账户", 175),
            ("activity", "最近活动", 150),
            ("status", "状态", 105)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            if identifier == "heat" { column.sortDescriptorPrototype = NSSortDescriptor(key: "heat", ascending: false) }
            if identifier == "commit" { column.sortDescriptorPrototype = NSSortDescriptor(key: "commitCount", ascending: false) }
            if identifier == "activity" { column.sortDescriptorPrototype = NSSortDescriptor(key: "activity", ascending: false) }
            if identifier == "text" { column.sortDescriptorPrototype = NSSortDescriptor(key: "text", ascending: true) }
            if identifier == "code" { column.sortDescriptorPrototype = NSSortDescriptor(key: "code", ascending: true) }
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        contextMenu.autoenablesItems = false
        for action in RimeAuditAction.allCases {
            let item = NSMenuItem(title: action.displayName, action: #selector(contextActionPressed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.toolTip = "对选中的词条执行“\(action.displayName)”"
            contextMenu.addItem(item)
        }
        tableView.menu = contextMenu
        tableView.onContextMenuRow = { [weak self] row in
            self?.prepareContextMenu(for: row)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        importProposalButton.toolTip = "导入 AI 生成的审核提案，只保存待审核状态"
        applyProposalButton.toolTip = "应用当前选中的 AI 提案，应用前会创建备份"
        addButton.toolTip = "手动添加一个长期记忆词条"
        restoreButton.toolTip = "从历史备份列表选择恢复；恢复前会自动保存当前状态"
        for button in [reviewButton, importProposalButton, applyProposalButton, addButton, restoreButton] {
            button.target = self
        }
        importProposalButton.action = #selector(importProposalPressed)
        applyProposalButton.action = #selector(applyProposalPressed)
        addButton.action = #selector(addPressed)
        restoreButton.action = #selector(restorePressed)

        selectAllButton.target = self
        selectAllButton.action = #selector(selectAllPressed)
        selectAllButton.allowsMixedState = true
        selectAllButton.setAccessibilityLabel("全选当前筛选结果")
        selectAllButton.toolTip = "全选当前筛选结果；再次点击会全部取消"
        selectAllButton.setContentHuggingPriority(.required, for: .horizontal)
        let selectionScopeLabel = NSTextField(labelWithString: "当前筛选结果")
        selectionScopeLabel.textColor = .secondaryLabelColor
        selectionScopeLabel.font = .systemFont(ofSize: 11)
        let selectionBar = NSStackView(views: [selectAllButton, selectionScopeLabel, NSView()])
        selectionBar.orientation = .horizontal
        selectionBar.alignment = .centerY
        selectionBar.spacing = 6

        let actionBar = NSStackView(views: [importProposalButton, applyProposalButton, NSView(), addButton, restoreButton])
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 8

        let stack = NSStackView(views: [firstRow, filters, selectionBar, scrollView, statusLabel, actionBar])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            firstRow.heightAnchor.constraint(equalToConstant: 30),
            filters.heightAnchor.constraint(equalToConstant: 46),
            selectionBar.heightAnchor.constraint(equalToConstant: 24),
            actionBar.heightAnchor.constraint(equalToConstant: 32),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            viewPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 105),
            exportButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 66)
        ])
    }

    private func configureExportMenu() {
        let menu = NSMenu(title: "导出")
        let titleItem = NSMenuItem(title: "导出", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        for format in RimeAuditExportFormat.allCases {
            let item = NSMenuItem(
                title: format.displayName,
                action: #selector(exportFormatPressed(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = format.rawValue
            item.toolTip = "导出当前筛选结果为 \(format.displayName)"
            menu.addItem(item)
        }
        exportButton.menu = menu
        exportButton.pullsDown = true
        exportButton.toolTip = "导出当前筛选结果，选择 CSV、TXT、Markdown 或 JSON"
    }

    private func labeled(_ title: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        return stack
    }

    private func configureSlider(_ slider: NSSlider, action: Selector) {
        slider.minValue = 0
        slider.maxValue = 4
        slider.numberOfTickMarks = 5
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = false
        slider.target = self
        slider.action = action
    }

    private func restorePreferences() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: PreferenceKey.view), let view = RimeAuditView(rawValue: raw) { viewPopup.selectItem(withTitle: view.displayName) }
        commitSlider.integerValue = defaults.integer(forKey: PreferenceKey.commit)
        heatSlider.integerValue = defaults.integer(forKey: PreferenceKey.heat)
        activitySlider.integerValue = defaults.integer(forKey: PreferenceKey.activity)
        searchField.stringValue = defaults.string(forKey: PreferenceKey.search) ?? ""
    }

    private var query: RimeAuditQuery {
        let defaults = UserDefaults.standard
        let view = viewPopup.selectedItem?.representedObject.flatMap { RimeAuditView(rawValue: $0 as? String ?? "") } ?? .recommendations
        let commit = RimeCommitCountBand.allCases[safe: commitSlider.integerValue] ?? .all
        let heat = RimeHeatBand.allCases[safe: heatSlider.integerValue] ?? .all
        let activity = RimeRecentActivityBand.allCases[safe: activitySlider.integerValue] ?? .all
        let sort = RimeAuditSortKey(rawValue: defaults.string(forKey: PreferenceKey.sort) ?? "heat") ?? .heat
        return RimeAuditQuery(view: view, commitBand: commit, heatBand: heat, activityBand: activity, search: searchField.stringValue, sortKey: sort, ascending: defaults.bool(forKey: PreferenceKey.ascending), includeStale: view == .noise)
    }

    private func savePreferences() {
        let defaults = UserDefaults.standard
        let current = query
        defaults.set(current.view.rawValue, forKey: PreferenceKey.view)
        defaults.set(commitSlider.integerValue, forKey: PreferenceKey.commit)
        defaults.set(heatSlider.integerValue, forKey: PreferenceKey.heat)
        defaults.set(activitySlider.integerValue, forKey: PreferenceKey.activity)
        defaults.set(searchField.stringValue, forKey: PreferenceKey.search)
        defaults.set(current.sortKey.rawValue, forKey: PreferenceKey.sort)
        defaults.set(current.ascending, forKey: PreferenceKey.ascending)
    }

    private func refreshFilter() {
        savePreferences()
        guard let batch else { filteredEntries = []; tableView.reloadData(); return }
        let currentQuery = query
        let result: RimeAuditFilterResult
        if cachedFilterQuery == currentQuery, let cachedFilterResult {
            result = cachedFilterResult
        } else {
            result = RimeAuditFilter.filter(batch.entries, query: currentQuery)
            cachedFilterQuery = currentQuery
            cachedFilterResult = result
        }
        filteredEntries = result.entries
        selectedIDs.formIntersection(Set(filteredEntries.map(\.id)))
        tableView.reloadData()
        thresholdLabel.stringValue = result.heatThreshold.map { String(format: "热度阈值 %.4g", $0) } ?? "热度不限"
        let activityHint: String
        if currentQuery.activityBand != .all,
           filteredEntries.isEmpty,
           !batch.entries.contains(where: { $0.lastActivityAt != nil }) {
            activityHint = "；历史快照的活动时间未知，后续同步观察到 c 增长后才会出现"
        } else {
            activityHint = ""
        }
        statusLabel.stringValue = "\(currentQuery.view.displayName)：显示 \(filteredEntries.count)/\(result.totalBeforePaging) 条；已选 \(selectedIDs.count) 条；\(lastSyncDescription)\(activityHint)"
        setControlsEnabled(true)
    }

    private func loadAudit(rebuild: Bool) {
        guard !isWorking else { return }
        isWorking = true
        setControlsEnabled(false)
        statusLabel.stringValue = rebuild ? "正在读取已同步快照并更新审核数据…" : "正在读取已保存的审核数据…"
        let coordinator = reviewCoordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result: RimeAuditBatch
                if rebuild {
                    result = try coordinator.refreshAuditFromPublishedSnapshots()
                } else {
                    guard let stored = try coordinator.latestBatch() else {
                        throw RimeSyncError.unsupportedOperation("尚未有已同步审核数据，请先在菜单栏点击“同步 Rime 词库”")
                    }
                    result = stored
                }
                let syncDate = try coordinator.syncMetadata().latestRecord?.synchronizedAt
                let state = try coordinator.reviewState()
                let proposals = Dictionary(
                    uniqueKeysWithValues: (state.proposals[result.batchID] ?? []).map { ($0.entryID, $0) }
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.batch = result
                    self.cachedFilterQuery = nil
                    self.cachedFilterResult = nil
                    self.proposalsByEntryID = proposals
                    self.lastSyncDescription = syncDate.map { "上次同步：\(Self.dateFormatter.string(from: $0))" } ?? "上次同步：未知"
                    self.selectedIDs.removeAll()
                    self.refreshFilter()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.statusLabel.stringValue = "读取失败：\(error.localizedDescription)"
                    self.setControlsEnabled(true)
                }
            }
        }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        let hasBatch = batch != nil
        reviewButton.isEnabled = enabled && !isWorking
        searchField.isEnabled = enabled && hasBatch
        viewPopup.isEnabled = enabled && hasBatch
        commitSlider.isEnabled = enabled && hasBatch
        heatSlider.isEnabled = enabled && hasBatch
        activitySlider.isEnabled = enabled && hasBatch
        exportButton.isEnabled = enabled && hasBatch
        importProposalButton.isEnabled = enabled && hasBatch
        applyProposalButton.isEnabled = enabled && hasBatch && !selectedIDs.isEmpty && selectedIDs.contains { proposalsByEntryID[$0] != nil }
        addButton.isEnabled = enabled
        restoreButton.isEnabled = enabled
        updateContextMenuState(enabled && hasBatch && !selectedIDs.isEmpty)
        updateSelectAllState(enabled && hasBatch)
    }

    @objc private func searchChanged() { refreshFilter() }
    @objc private func filterChanged() { refreshFilter() }
    @objc private func commitBandChanged() { refreshFilter() }
    @objc private func heatBandChanged() { refreshFilter() }
    @objc private func activityBandChanged() { refreshFilter() }
    @objc private func reviewPressed() { loadAudit(rebuild: false) }
    @objc private func selectAllPressed() { toggleSelectAll() }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        refreshFilter()
    }

    private func toggleSelectAll() {
        guard batch != nil, !isWorking else { return }
        let visibleIDs = Set(filteredEntries.map(\.id))
        guard !visibleIDs.isEmpty else { return }
        let visibleSelectedIDs = selectedIDs.intersection(visibleIDs)
        if visibleSelectedIDs.count == visibleIDs.count {
            selectedIDs.subtract(visibleIDs)
        } else {
            selectedIDs.formUnion(visibleIDs)
        }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<filteredEntries.count), columnIndexes: IndexSet(integer: 0))
        updateSelectionUI()
    }

    @objc private func rowCheckboxPressed(_ sender: NSButton) {
        guard filteredEntries.indices.contains(sender.tag), !isWorking else { return }
        let id = filteredEntries[sender.tag].id
        if sender.state == .on {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
        updateSelectionUI()
    }

    private func updateSelectionUI() {
        applyProposalButton.isEnabled = !selectedIDs.isEmpty && !isWorking && selectedIDs.contains { proposalsByEntryID[$0] != nil }
        updateContextMenuState(!isWorking && batch != nil && !selectedIDs.isEmpty)
        updateSelectAllState(!isWorking && batch != nil)
        statusLabel.stringValue = "\(query.view.displayName)：显示 \(filteredEntries.count) 条；已选 \(selectedIDs.count) 条；\(lastSyncDescription)"
    }

    private func updateSelectAllState(_ enabled: Bool) {
        let visibleIDs = Set(filteredEntries.map(\.id))
        let selectedVisibleCount = selectedIDs.intersection(visibleIDs).count
        selectAllButton.isEnabled = enabled && !visibleIDs.isEmpty
        if visibleIDs.isEmpty || selectedVisibleCount == 0 {
            selectAllButton.state = .off
        } else if selectedVisibleCount == visibleIDs.count {
            selectAllButton.state = .on
        } else {
            selectAllButton.state = .mixed
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        UserDefaults.standard.set(descriptor.key ?? "heat", forKey: PreferenceKey.sort)
        UserDefaults.standard.set(descriptor.ascending, forKey: PreferenceKey.ascending)
        refreshFilter()
    }

    private func prepareContextMenu(for row: Int) {
        guard filteredEntries.indices.contains(row), !isWorking else { return }
        let id = filteredEntries[row].id
        if !selectedIDs.contains(id) {
            selectedIDs.insert(id)
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            updateSelectionUI()
        }
        if tableView.selectedRowIndexes.contains(row) == false {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateContextMenuState(batch != nil && !selectedIDs.isEmpty)
    }

    private func updateContextMenuState(_ enabled: Bool) {
        for item in contextMenu.items {
            item.isEnabled = enabled
        }
    }

    @objc private func contextActionPressed(_ sender: NSMenuItem) {
        guard !selectedIDs.isEmpty, !isWorking,
              let raw = sender.representedObject as? String,
              let action = RimeAuditAction(rawValue: raw) else { return }
        guard action != .replaceEntry else {
            showMessage(title: "replace_entry 需要目标词", text: "请导入并确认包含 replacementText 和 replacementCode 的 AI 提案。")
            return
        }
        apply(actions: Dictionary(uniqueKeysWithValues: selectedIDs.map { ($0, action) }), description: action.displayName)
    }

    @objc private func applyProposalPressed() {
        guard !selectedIDs.isEmpty, !isWorking else { return }
        let proposals = selectedIDs.compactMap { proposalsByEntryID[$0] }
        guard !proposals.isEmpty else {
            showMessage(title: "没有可应用的 AI 提案", text: "当前选择中没有已校验的 AI 提案。")
            return
        }
        apply(proposals: proposals, description: "AI 提案")
    }

    private func apply(actions: [String: RimeAuditAction], description: String) {
        guard let batch, !actions.isEmpty, !isWorking else { return }
        isWorking = true
        setControlsEnabled(false)
        statusLabel.stringValue = "正在应用“\(description)”…"
        let coordinator = reviewCoordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try coordinator.apply(batch: batch, actions: actions)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.selectedIDs.removeAll()
                    self.statusLabel.stringValue = "已处理：替换 \(report.replacedCount)，长期记忆 \(report.importedCount)，删除 \(report.deletedCount)，永久忽略 \(report.ignoredCount)；备份 \(report.backupID)"
                    self.loadAudit(rebuild: true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.statusLabel.stringValue = "应用失败：\(error.localizedDescription)"
                    self.setControlsEnabled(true)
                }
            }
        }
    }

    private func apply(proposals: [RimeAuditProposal], description: String) {
        guard let batch, !proposals.isEmpty, !isWorking else { return }
        isWorking = true
        setControlsEnabled(false)
        statusLabel.stringValue = "正在应用“\(description)”…"
        let coordinator = reviewCoordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try coordinator.apply(proposals: proposals, for: batch)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.selectedIDs.removeAll()
                    self.statusLabel.stringValue = "已处理：替换 \(report.replacedCount)，长期记忆 \(report.importedCount)，删除 \(report.deletedCount)，永久忽略 \(report.ignoredCount)；备份 \(report.backupID)"
                    self.loadAudit(rebuild: true)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.statusLabel.stringValue = "应用失败：\(error.localizedDescription)"
                    self.setControlsEnabled(true)
                }
            }
        }
    }

    @objc private func exportFormatPressed(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let format = RimeAuditExportFormat(rawValue: rawValue),
              let batch else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rime-audit-\(batch.batchID).\(format.fileExtension)"
        switch format {
        case .csv: panel.allowedContentTypes = [.commaSeparatedText]
        case .json: panel.allowedContentTypes = [.json]
        case .txt, .markdown: panel.allowedContentTypes = [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try reviewCoordinator.export(batch: batch, entries: filteredEntries, format: format)
            try data.write(to: url, options: .atomic)
            statusLabel.stringValue = "已导出 \(filteredEntries.count) 条：\(url.lastPathComponent)"
        }
        catch { statusLabel.stringValue = "导出失败：\(error.localizedDescription)" }
    }

    @objc private func importProposalPressed() {
        guard let batch else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preview = try reviewCoordinator.importProposalCSV(data: Data(contentsOf: url), for: batch)
            let state = try reviewCoordinator.reviewState()
            proposalsByEntryID = Dictionary(
                uniqueKeysWithValues: (state.proposals[batch.batchID] ?? []).map { ($0.entryID, $0) }
            )
            let details = preview.countsByAction.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)" }.joined(separator: "\n")
            let replacements = preview.replacements.map { "replace_entry：\($0.oldText) → \($0.replacementText)；来源 \($0.sourceEntries.count) 个；新词将永久保存" }.joined(separator: "\n")
            let suffix = replacements.isEmpty ? "" : "\n\(replacements)"
            showMessage(title: "AI 提案已保存", text: "共 \(preview.proposalCount) 条，尚未修改 userdb。\n\(details)\(suffix)")
        } catch { showMessage(title: "AI 提案无效", text: error.localizedDescription) }
    }

    @objc private func addPressed() {
        guard !isWorking else { return }
        let form = ManualRimeEntryForm()
        let alert = NSAlert()
        alert.messageText = "手动添加 Rime 词条"
        alert.informativeText = "词条会成为长期记忆，写入独立的 rime_managed.dict.yaml。"
        alert.accessoryView = form
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = form.wordField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let frequencyText = form.frequencyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frequency = frequencyText.isEmpty ? nil : Int(frequencyText)
        guard frequencyText.isEmpty || frequency != nil else { statusLabel.stringValue = "添加失败：频率必须是整数"; return }
        isWorking = true; setControlsEnabled(false); statusLabel.stringValue = "正在添加词条…"
        let coordinator = reviewCoordinator
        let word = form.wordField.stringValue
        let code = form.codeField.stringValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try coordinator.addManualEntry(text: word, code: code, frequency: frequency)
                DispatchQueue.main.async { guard let self else { return }; self.isWorking = false; self.statusLabel.stringValue = "已手动添加；备份 \(report.backupID)"; self.loadAudit(rebuild: true) }
            } catch {
                DispatchQueue.main.async { guard let self else { return }; self.isWorking = false; self.statusLabel.stringValue = "添加失败：\(error.localizedDescription)"; self.setControlsEnabled(true) }
            }
        }
    }

    @objc private func restorePressed() {
        guard !isWorking else { return }
        isWorking = true
        setControlsEnabled(false)
        statusLabel.stringValue = "正在读取备份列表…"
        let coordinator = reviewCoordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let backups = try coordinator.listBackups()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.setControlsEnabled(true)
                    self.presentBackupPicker(backups)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.statusLabel.stringValue = "读取备份失败：\(error.localizedDescription)"
                    self.setControlsEnabled(true)
                }
            }
        }
    }

    private func presentBackupPicker(_ backups: [RimeBackupDescriptor]) {
        guard !backups.isEmpty else {
            statusLabel.stringValue = "暂无可恢复备份"
            showMessage(title: "暂无可恢复备份", text: "当前账户还没有可恢复的 Rime 备份。")
            return
        }

        let picker = RimeBackupPickerView(
            backups: backups,
            retentionLimit: reviewCoordinator.backupRetentionLimit
        )
        picker.onRetentionSaved = { [weak self] policy in
            guard let self else { return }
            do {
                _ = try self.reviewCoordinator.updateBackupRetentionLimit(policy.limit)
                RimeBackupSettings.save(policy)
            } catch {
                self.statusLabel.stringValue = "保存备份数量失败：\(error.localizedDescription)"
            }
        }

        let alert = NSAlert()
        alert.messageText = "恢复 Rime 备份"
        alert.informativeText = "选择要恢复的备份。恢复前会自动保存当前状态，恢复成功后才会按保留数量清理旧备份。"
        alert.accessoryView = picker
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = picker.tableView
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let policy = try picker.validatedRetentionPolicy()
            _ = try reviewCoordinator.updateBackupRetentionLimit(policy.limit)
            RimeBackupSettings.save(policy)
            guard let backup = picker.selectedBackup else {
                statusLabel.stringValue = "恢复已取消：未选择备份"
                return
            }

            let confirmation = NSAlert()
            confirmation.messageText = "确认恢复此备份？"
            confirmation.informativeText = "将恢复 \(backup.id)（\(backup.nodeID)）的 Rime 状态。当前状态会先自动备份。"
            confirmation.addButton(withTitle: "恢复")
            confirmation.addButton(withTitle: "取消")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }

            isWorking = true
            setControlsEnabled(false)
            statusLabel.stringValue = "正在恢复备份…"
            let coordinator = reviewCoordinator
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try coordinator.restore(backupID: backup.id)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isWorking = false
                        self.statusLabel.stringValue = "已恢复备份；正在重新读取…"
                        self.loadAudit(rebuild: true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.isWorking = false
                        self.statusLabel.stringValue = "恢复失败：\(error.localizedDescription)"
                        self.setControlsEnabled(true)
                    }
                }
            }
        } catch {
            statusLabel.stringValue = "恢复已取消：\(error.localizedDescription)"
            showMessage(title: "备份数量无效", text: error.localizedDescription)
        }
    }

    private func showMessage(title: String, text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "好"); alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, filteredEntries.indices.contains(row) else { return nil }
        let entry = filteredEntries[row]
        if tableColumn.identifier.rawValue == "select" {
            let identifier = NSUserInterfaceItemIdentifier("RimeAuditCheckboxCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? RimeAuditCheckboxCell) ?? makeCheckboxCell(identifier: identifier)
            cell.checkbox.tag = row
            cell.checkbox.state = selectedIDs.contains(entry.id) ? .on : .off
            cell.checkbox.isEnabled = !isWorking
            return cell
        }
        let cell = (tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView) ?? makeCell()
        let value: String
        switch tableColumn.identifier.rawValue {
        case "text": value = entry.text
        case "code": value = entry.code
        case "commit": value = "\(entry.commitCount)"
        case "heat": value = String(format: "%.4g", entry.rimeScore)
        case "source": value = entry.sourceNodes.joined(separator: "、")
        case "activity": value = entry.lastActivityAt.map { Self.dateFormatter.string(from: $0) } ?? "历史未知"
        case "status":
            if let proposal = proposalsByEntryID[entry.id] {
                if proposal.action == .replaceEntry {
                    value = "replace_entry：\(entry.text) → \(proposal.replacementText ?? "待补充")"
                } else {
                    value = "AI建议·\(proposal.action.displayName)"
                }
            } else if entry.generatedByReplaceEntry == true {
                value = "replace_entry 生成·永久词条"
            } else {
                value = entry.isNoise ? "疑似噪音" : Self.statusName(entry.currentStatus)
            }
        default: value = ""
        }
        cell.textField?.stringValue = value
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellIdentifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func makeCheckboxCell(identifier: NSUserInterfaceItemIdentifier) -> RimeAuditCheckboxCell {
        let cell = RimeAuditCheckboxCell(frame: .zero)
        cell.identifier = identifier
        cell.checkbox.target = self
        cell.checkbox.action = #selector(rowCheckboxPressed(_:))
        return cell
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "yyyy-MM-dd HH:mm"; return formatter
    }()

    private static func statusName(_ status: RimeAuditStatus) -> String {
        switch status {
        case .dynamic: return "动态学习"
        case .newRecord: return "新增"
        case .changed: return "有变化"
        case .permanent: return "长期记忆"
        case .ignored: return "永久忽略"
        case .pending: return "待处理"
        case .manualReview: return "人工确认"
        case .deleted: return "已删除"
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
