import AppKit
import RimeSyncCore

@MainActor
final class RimeBackupPickerView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let backups: [RimeBackupDescriptor]
    let tableView = NSTableView()
    let retentionField = NSTextField()

    var onRetentionSaved: ((RimeBackupRetentionPolicy) -> Void)?

    private let retentionStatusLabel = NSTextField(labelWithString: "")
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(backups: [RimeBackupDescriptor], retentionLimit: Int) {
        self.backups = backups
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 340))

        retentionField.stringValue = "\(retentionLimit)"
        retentionField.placeholderString = "正整数"
        retentionField.toolTip = "每个账户保留的备份数量；只能填写大于等于 1 的整数"
        retentionField.alignment = .right
        retentionField.translatesAutoresizingMaskIntoConstraints = false

        let retentionLabel = NSTextField(labelWithString: "保留备份数量")
        retentionLabel.toolTip = "修改后从下一次创建备份时开始清理旧备份"
        let retentionSaveButton = NSButton(title: "保存数量", target: self, action: #selector(saveRetentionPressed))
        retentionSaveButton.bezelStyle = .rounded
        retentionSaveButton.toolTip = "校验并保存当前账户的备份保留数量"
        retentionSaveButton.setContentHuggingPriority(.required, for: .horizontal)

        retentionStatusLabel.textColor = .secondaryLabelColor
        retentionStatusLabel.font = .systemFont(ofSize: 11)
        retentionStatusLabel.lineBreakMode = .byTruncatingTail

        let retentionRow = NSStackView(views: [retentionLabel, retentionField, retentionSaveButton, retentionStatusLabel, NSView()])
        retentionRow.orientation = .horizontal
        retentionRow.alignment = .centerY
        retentionRow.spacing = 8
        retentionRow.translatesAutoresizingMaskIntoConstraints = false

        configureTable()
        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "恢复前会自动创建当前状态的回滚备份；恢复成功后才会按数量清理旧备份。")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byWordWrapping
        hint.toolTip = "恢复失败时，程序会尝试使用自动创建的回滚备份恢复当前状态"

        let content = NSStackView(views: [retentionRow, scrollView, hint])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            retentionRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            retentionField.widthAnchor.constraint(equalToConstant: 90),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 245),
            hint.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var selectedBackup: RimeBackupDescriptor? {
        guard backups.indices.contains(tableView.selectedRow) else { return nil }
        return backups[tableView.selectedRow]
    }

    func validatedRetentionPolicy() throws -> RimeBackupRetentionPolicy {
        let text = retentionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw RimeSyncError.unsupportedOperation("备份保留数量不能为空")
        }
        guard let value = Int(text) else {
            throw RimeSyncError.unsupportedOperation("备份保留数量必须是整数")
        }
        return try RimeBackupRetentionPolicy(limit: value)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { backups.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, backups.indices.contains(row) else { return nil }
        let descriptor = backups[row]
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.stringValue = value(for: tableColumn.identifier.rawValue, descriptor: descriptor)
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func saveRetentionPressed() {
        do {
            let policy = try validatedRetentionPolicy()
            onRetentionSaved?(policy)
            retentionStatusLabel.stringValue = "已保存：\(policy.limit) 份"
        } catch {
            retentionStatusLabel.stringValue = "保存失败：\(error.localizedDescription)"
        }
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 25
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.headerView = NSTableHeaderView()
        tableView.setAccessibilityLabel("可恢复的 Rime 备份")

        let columns: [(String, String, CGFloat)] = [
            ("date", "时间", 165),
            ("node", "账户", 90),
            ("id", "备份 ID", 345)
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = width
            tableView.addTableColumn(column)
        }

        tableView.reloadData()
        if !backups.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func value(for column: String, descriptor: RimeBackupDescriptor) -> String {
        switch column {
        case "date": return descriptor.createdAt.map(dateFormatter.string(from:)) ?? "时间未知"
        case "node": return descriptor.nodeID
        case "id": return descriptor.id
        default: return ""
        }
    }
}
