import AppKit
import RimeSyncCore

@MainActor
final class RimeDictionaryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let reviewCoordinator: RimeReviewSyncCoordinator
    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let viewPopup = NSPopUpButton()
    private let actionPopup = NSPopUpButton()
    private let commitSlider = NSSlider()
    private let heatSlider = NSSlider()
    private let activitySlider = NSSlider()
    private let statusLabel = NSTextField(labelWithString: "尚未读取快照")
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let selectAllButton = NSButton(title: "全选当前结果", target: nil, action: nil)
    private let clearSelectionButton = NSButton(title: "清除选择", target: nil, action: nil)
    private let reviewButton = NSButton(title: "重新读取快照", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出 CSV…", target: nil, action: nil)
    private let importProposalButton = NSButton(title: "导入 AI 提案…", target: nil, action: nil)
    private let applyProposalButton = NSButton(title: "应用 AI 提案", target: nil, action: nil)
    private let applyButton = NSButton(title: "应用所选动作", target: nil, action: nil)
    private let addButton = NSButton(title: "手动添加词条…", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复备份…", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)

    private var batch: RimeAuditBatch?
    private var proposalsByEntryID: [String: RimeAuditProposal] = [:]
    private var filteredEntries: [RimeAuditEntry] = []
    private var selectedIDs = Set<String>()
    private var isWorking = false

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

    func begin() { loadAudit() }

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

        for action in RimeAuditAction.allCases {
            actionPopup.addItem(withTitle: action.displayName)
            actionPopup.lastItem?.representedObject = action.rawValue
        }
        actionPopup.target = self

        configureSlider(commitSlider, action: #selector(commitBandChanged))
        configureSlider(heatSlider, action: #selector(heatBandChanged))
        configureSlider(activitySlider, action: #selector(activityBandChanged))
        commitSlider.toolTip = "累计次数：全部、≥3、≥10、≥30、≥100"
        heatSlider.toolTip = "有效热度：全部、前 50%、前 25%、前 10%、前 1%"
        activitySlider.toolTip = "最近活动：全部、近一年、近半年、近一月、近一周"

        let firstRow = NSStackView(views: [searchField, labeled("视图", viewPopup), NSView(), reviewButton])
        firstRow.orientation = .horizontal
        firstRow.alignment = .centerY
        firstRow.spacing = 10
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        viewPopup.setContentHuggingPriority(.required, for: .horizontal)
        reviewButton.target = self
        reviewButton.action = #selector(reviewPressed)

        let filters = NSStackView(views: [
            labeled("累计次数", commitSlider),
            labeled("有效热度", heatSlider),
            labeled("最近活动", activitySlider),
            thresholdLabel
        ])
        filters.orientation = .horizontal
        filters.alignment = .centerY
        filters.spacing = 16
        thresholdLabel.textColor = .secondaryLabelColor
        thresholdLabel.font = .systemFont(ofSize: 11)

        let columns: [(String, String, CGFloat)] = [
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
            if identifier == "commit" { column.sortDescriptorPrototype = NSSortDescriptor(key: "commit", ascending: false) }
            tableView.addTableColumn(column)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        for button in [selectAllButton, clearSelectionButton, reviewButton, exportButton, importProposalButton, applyProposalButton, applyButton, addButton, restoreButton, closeButton] {
            button.target = self
        }
        selectAllButton.action = #selector(selectAllPressed)
        clearSelectionButton.action = #selector(clearSelectionPressed)
        exportButton.action = #selector(exportPressed)
        importProposalButton.action = #selector(importProposalPressed)
        applyProposalButton.action = #selector(applyProposalPressed)
        applyButton.action = #selector(applyPressed)
        addButton.action = #selector(addPressed)
        restoreButton.action = #selector(restorePressed)
        closeButton.action = #selector(closePressed)
        applyButton.keyEquivalent = "\r"

        let actionBar = NSStackView(views: [actionPopup, applyButton, applyProposalButton, NSView(), selectAllButton, clearSelectionButton, exportButton, importProposalButton, addButton, restoreButton, closeButton])
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = 8

        let stack = NSStackView(views: [firstRow, filters, scrollView, statusLabel, actionBar])
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
            filters.heightAnchor.constraint(equalToConstant: 32),
            actionBar.heightAnchor.constraint(equalToConstant: 32),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            viewPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 105),
            actionPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 125)
        ])
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
        slider.target = self
        slider.action = action
        slider.widthAnchor.constraint(equalToConstant: 125).isActive = true
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
        let result = RimeAuditFilter.filter(batch.entries, query: query)
        filteredEntries = result.entries
        selectedIDs.formIntersection(Set(filteredEntries.map(\.id)))
        tableView.reloadData()
        let selectedRows = IndexSet(filteredEntries.indices.filter { selectedIDs.contains(filteredEntries[$0].id) })
        if !selectedRows.isEmpty { tableView.selectRowIndexes(selectedRows, byExtendingSelection: false) }
        thresholdLabel.stringValue = result.heatThreshold.map { String(format: "热度阈值 %.4g", $0) } ?? "热度不限"
        statusLabel.stringValue = "\(query.view.displayName)：显示 \(filteredEntries.count)/\(result.totalBeforePaging) 条；已选 \(selectedIDs.count) 条"
        setControlsEnabled(true)
    }

    private func loadAudit() {
        guard !isWorking else { return }
        isWorking = true
        setControlsEnabled(false)
        statusLabel.stringValue = "正在备份当前快照并读取审核数据…"
        let coordinator = reviewCoordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try coordinator.prepareAudit()
                let state = try coordinator.reviewState()
                let proposals = Dictionary(
                    uniqueKeysWithValues: (state.proposals[result.batchID] ?? []).map { ($0.entryID, $0) }
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isWorking = false
                    self.batch = result
                    self.proposalsByEntryID = proposals
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
        actionPopup.isEnabled = enabled && hasBatch && !selectedIDs.isEmpty
        commitSlider.isEnabled = enabled && hasBatch
        heatSlider.isEnabled = enabled && hasBatch
        activitySlider.isEnabled = enabled && hasBatch
        selectAllButton.isEnabled = enabled && hasBatch
        clearSelectionButton.isEnabled = enabled && hasBatch && !selectedIDs.isEmpty
        exportButton.isEnabled = enabled && hasBatch
        importProposalButton.isEnabled = enabled && hasBatch
        applyProposalButton.isEnabled = enabled && hasBatch && !selectedIDs.isEmpty && selectedIDs.contains { proposalsByEntryID[$0] != nil }
        applyButton.isEnabled = enabled && hasBatch && !selectedIDs.isEmpty
        addButton.isEnabled = enabled
        restoreButton.isEnabled = enabled
    }

    @objc private func searchChanged() { refreshFilter() }
    @objc private func filterChanged() { refreshFilter() }
    @objc private func commitBandChanged() { refreshFilter() }
    @objc private func heatBandChanged() { refreshFilter() }
    @objc private func activityBandChanged() { refreshFilter() }
    @objc private func reviewPressed() { loadAudit() }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        refreshFilter()
    }

    @objc private func selectAllPressed() {
        selectedIDs.formUnion(filteredEntries.map(\.id))
        refreshFilter()
    }

    @objc private func clearSelectionPressed() {
        selectedIDs.removeAll()
        refreshFilter()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIDs = Set(tableView.selectedRowIndexes.compactMap { filteredEntries.indices.contains($0) ? filteredEntries[$0].id : nil })
        actionPopup.isEnabled = !selectedIDs.isEmpty && !isWorking
        applyProposalButton.isEnabled = !selectedIDs.isEmpty && !isWorking && selectedIDs.contains { proposalsByEntryID[$0] != nil }
        applyButton.isEnabled = !selectedIDs.isEmpty && !isWorking
        clearSelectionButton.isEnabled = !selectedIDs.isEmpty && !isWorking
        statusLabel.stringValue = "\(query.view.displayName)：显示 \(filteredEntries.count) 条；已选 \(selectedIDs.count) 条"
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first else { return }
        UserDefaults.standard.set(descriptor.key ?? "heat", forKey: PreferenceKey.sort)
        UserDefaults.standard.set(descriptor.ascending, forKey: PreferenceKey.ascending)
        refreshFilter()
    }

    @objc private func applyPressed() {
        guard batch != nil, !selectedIDs.isEmpty, !isWorking,
              let raw = actionPopup.selectedItem?.representedObject as? String,
              let action = RimeAuditAction(rawValue: raw) else { return }
        apply(actions: Dictionary(uniqueKeysWithValues: selectedIDs.map { ($0, action) }), description: action.displayName)
    }

    @objc private func applyProposalPressed() {
        guard !selectedIDs.isEmpty, !isWorking else { return }
        let actions = Dictionary(uniqueKeysWithValues: selectedIDs.compactMap { id in
            proposalsByEntryID[id].map { (id, $0.action) }
        })
        guard !actions.isEmpty else {
            showMessage(title: "没有可应用的 AI 提案", text: "当前选择中没有已校验的 AI 提案。")
            return
        }
        apply(actions: actions, description: "AI 提案")
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
                    self.statusLabel.stringValue = "已处理：长期记忆 \(report.importedCount)，删除 \(report.deletedCount)，永久忽略 \(report.ignoredCount)；备份 \(report.backupID)"
                    self.loadAudit()
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

    @objc private func exportPressed() {
        guard let batch else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "rime-audit-\(batch.batchID).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try reviewCoordinator.export(batch: batch).write(to: url, options: .atomic); statusLabel.stringValue = "已导出审核表：\(url.lastPathComponent)" }
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
            showMessage(title: "AI 提案已保存", text: "共 \(preview.proposalCount) 条，尚未修改 userdb。\n\(details)")
        } catch { showMessage(title: "AI 提案无效", text: error.localizedDescription) }
    }

    @objc private func addPressed() {
        guard !isWorking else { return }
        let wordField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); wordField.placeholderString = "词条（必填）"
        let codeField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); codeField.placeholderString = "全拼编码（必填）"
        let frequencyField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); frequencyField.placeholderString = "频率（仅用于校验，默认 1）"
        let fields = NSStackView(views: [wordField, codeField, frequencyField]); fields.orientation = .vertical; fields.spacing = 8; fields.frame = NSRect(x: 0, y: 0, width: 380, height: 90)
        let alert = NSAlert(); alert.messageText = "手动添加 Rime 词条"; alert.informativeText = "词条会成为长期记忆，写入独立的 rime_managed.dict.yaml。"; alert.accessoryView = fields; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let frequencyText = frequencyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frequency = frequencyText.isEmpty ? nil : Int(frequencyText)
        guard frequencyText.isEmpty || frequency != nil else { statusLabel.stringValue = "添加失败：频率必须是整数"; return }
        isWorking = true; setControlsEnabled(false); statusLabel.stringValue = "正在添加词条…"
        let coordinator = reviewCoordinator; let word = wordField.stringValue; let code = codeField.stringValue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let report = try coordinator.addManualEntry(text: word, code: code, frequency: frequency)
                DispatchQueue.main.async { guard let self else { return }; self.isWorking = false; self.statusLabel.stringValue = "已手动添加；备份 \(report.backupID)"; self.loadAudit() }
            } catch {
                DispatchQueue.main.async { guard let self else { return }; self.isWorking = false; self.statusLabel.stringValue = "添加失败：\(error.localizedDescription)"; self.setControlsEnabled(true) }
            }
        }
    }

    @objc private func restorePressed() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); field.placeholderString = "备份 ID"
        let alert = NSAlert(); alert.messageText = "恢复 Rime 备份"; alert.informativeText = "恢复前会再次创建当前状态备份。请输入明确的备份 ID。"; alert.accessoryView = field; alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ID = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); guard !ID.isEmpty else { return }
        do { try reviewCoordinator.restore(backupID: ID); statusLabel.stringValue = "已恢复备份 \(ID)"; loadAudit() }
        catch { statusLabel.stringValue = "恢复失败：\(error.localizedDescription)" }
    }

    private func showMessage(title: String, text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.addButton(withTitle: "好"); alert.runModal()
    }

    @objc private func closePressed() { window?.performClose(nil) }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, filteredEntries.indices.contains(row) else { return nil }
        let entry = filteredEntries[row]
        let cell = NSTableCellView()
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
                value = "AI建议·\(proposal.action.displayName)"
            } else {
                value = entry.isNoise ? "疑似噪音" : Self.statusName(entry.currentStatus)
            }
        default: value = ""
        }
        let field = NSTextField(labelWithString: value); field.lineBreakMode = .byTruncatingTail; field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
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
