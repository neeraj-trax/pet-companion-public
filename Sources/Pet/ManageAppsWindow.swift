import AppKit
import UniformTypeIdentifiers

/// Pet's apps: a small window listing the pinned apps, with drag-to-reorder, + and −.
/// Every change is saved straight to ShortcutStore and reported through `onChange`.
final class ManageAppsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ManageAppsWindowController()

    /// Called after any edit so the ring of icons can reload.
    var onChange: (() -> Void)?

    private let store = ShortcutStore.shared
    private let table = ManageAppsTableView()
    private let removeButton = NSButton()
    private var previousApp: NSRunningApplication?
    private static let dragType = NSPasteboard.PasteboardType("com.pet.manage-apps.row")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Pet's apps"
        window.minSize = NSSize(width: 300, height: 260)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Show / hide

    func show() {
        guard let window else { return }
        if !window.isVisible {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
            window.center()
        }
        table.reloadData()
        updateButtons()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let previous = previousApp, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: previous) }
            previous.activate(options: [])
        }
        previousApp = nil
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.title = "App"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 36
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.registerForDraggedTypes([Self.dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.onDelete = { [weak self] in self?.removeSelected() }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add app")!,
                                 target: self, action: #selector(addApps))
        addButton.bezelStyle = .smallSquare
        addButton.toolTip = "Add an app"
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove app")
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.toolTip = "Remove the selected app"
        for b in [addButton, removeButton] {
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let hint = NSTextField(labelWithString: "Rest the cursor on Pet to open the ring")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [addButton, removeButton, hint])
        footer.orientation = .horizontal
        footer.spacing = 6
        footer.alignment = .centerY
        footer.setCustomSpacing(12, after: removeButton)
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        updateButtons()
    }

    private func updateButtons() {
        removeButton.isEnabled = table.selectedRowIndexes.count > 0
    }

    private func changed() {
        table.reloadData()
        updateButtons()
        onChange?()
    }

    // MARK: - Actions

    @objc private func addApps() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Pick apps for Pet's ring"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            for url in panel.urls { self.store.add(url) }
            self.changed()
        }
    }

    @objc private func removeSelected() {
        let selected = table.selectedRowIndexes
        guard !selected.isEmpty else { return }
        for row in selected.reversed() where store.apps.indices.contains(row) {
            store.remove(store.apps[row])
        }
        changed()
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { store.apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? makeCell(id)
        let url = store.apps[row]
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 28, height: 28)
        cell.imageView?.image = icon
        cell.textField?.stringValue = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        for v in [image, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 28),
            image.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: - Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let str = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.dragType),
              let from = Int(str) else { return false }
        store.move(from: from, to: row)
        changed()
        let newRow = row > from ? row - 1 : row
        table.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        return true
    }
}

/// Table that removes the selected rows on Delete / Backspace.
final class ManageAppsTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
        if key == 0x7F || key == UInt32(NSDeleteFunctionKey) || key == 8, selectedRow >= 0 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}
