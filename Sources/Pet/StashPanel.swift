import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// A small, nonactivating shelf for things kept in Stash. It floats over full-screen apps
/// without moving the user to Finder, and every item can be dragged into another app.
final class StashPanel: NSPanel, NSCollectionViewDataSource, NSCollectionViewDelegate,
                        QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private static let itemID = NSUserInterfaceItemIdentifier("stash-item")

    private let collection = StashCollectionView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Nothing here yet\nDrop a file on Pet to keep it close")
    private let selectionLabel = NSTextField(labelWithString: "Select a file to preview or remove")
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private var urls: [URL] = []
    private var previewURL: URL?
    private var undoItems: [StashStore.RemovedItem] = []
    private(set) var isShown = false

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 480, height: 390),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        buildUI()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func buildUI() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        contentView = background

        let title = NSTextField(labelWithString: "Stash")
        title.font = UI.roundedFont(17, .semibold)
        title.textColor = .labelColor

        hintLabel.font = UI.roundedFont(11, .medium)
        hintLabel.textColor = .secondaryLabelColor

        let heading = NSStackView(views: [title, hintLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2
        heading.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Stash")!,
                             target: self, action: #selector(closeShelf))
        close.bezelStyle = .shadowlessSquare
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 98, height: 112)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.register(StashItemView.self, forItemWithIdentifier: Self.itemID)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.onOpen = { [weak self] indexPath in
            self?.previewItem(at: indexPath)
        }

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = UI.roundedFont(14, .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        selectionLabel.font = UI.roundedFont(11, .medium)
        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.translatesAutoresizingMaskIntoConstraints = false
        for button in [previewButton, removeButton, undoButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        previewButton.target = self
        previewButton.action = #selector(previewSelected)
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelColor = .systemRed
        removeButton.toolTip = "Moves only the Stash copy to Trash; the original stays where it was"
        undoButton.target = self
        undoButton.action = #selector(undoRemoval)
        undoButton.isHidden = true
        previewButton.isEnabled = false
        removeButton.isEnabled = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        for item in [selectionLabel, undoButton, previewButton, removeButton] { footer.addSubview(item) }

        background.addSubview(heading)
        background.addSubview(close)
        background.addSubview(scroll)
        background.addSubview(emptyLabel)
        background.addSubview(footer)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            close.topAnchor.constraint(equalTo: background.topAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -40),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 30),
            selectionLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            selectionLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            selectionLabel.trailingAnchor.constraint(lessThanOrEqualTo: undoButton.leadingAnchor, constant: -6),
            undoButton.trailingAnchor.constraint(equalTo: previewButton.leadingAnchor, constant: -7),
            undoButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            previewButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -7),
            previewButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    func reload() {
        urls = StashStore.shared.items
        collection.selectionIndexPaths = []
        collection.reloadData()
        emptyLabel.isHidden = !urls.isEmpty
        hintLabel.stringValue = urls.isEmpty
            ? "Your portable file shelf"
            : "\(urls.count) \(urls.count == 1 ? "item" : "items") · drag into any app"
        updateSelection()
    }

    func show(near petRect: CGRect, screen: CGRect) {
        reload()
        let size = frame.size
        let inset: CGFloat = 12
        let minX = screen.minX + inset
        let maxX = max(minX, screen.maxX - size.width - inset)
        let x = min(max(petRect.midX - size.width / 2, minX), maxX)
        let above = petRect.maxY + 14
        let below = petRect.minY - size.height - 14
        let y = above + size.height <= screen.maxY - inset
            ? above
            : max(screen.minY + inset, below)
        setFrameOrigin(CGPoint(x: x.rounded(), y: y.rounded()))
        alphaValue = 1
        orderFrontRegardless()
        isShown = true
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        clearUndo()
        orderOut(nil)
    }

    @objc private func closeShelf() { hide() }

    // MARK: Collection

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath)
        if let item = item as? StashItemView, urls.indices.contains(indexPath.item) {
            item.configure(with: urls[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard urls.indices.contains(indexPath.item) else { return nil }
        return urls[indexPath.item] as NSURL
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        if operation.contains(.copy) || operation.contains(.move) { hide() }
    }

    private var selectedURLs: [URL] {
        collection.selectionIndexPaths.sorted { $0.item < $1.item }.compactMap { indexPath in
            urls.indices.contains(indexPath.item) ? urls[indexPath.item] : nil
        }
    }

    private func updateSelection() {
        let count = selectedURLs.count
        previewButton.isEnabled = count == 1
        removeButton.isEnabled = count > 0
        selectionLabel.stringValue = count == 0
            ? "Select a file to preview or remove"
            : "\(count) \(count == 1 ? "item" : "items") selected"
    }

    @objc private func previewSelected() {
        guard let selected = collection.selectionIndexPaths.first else { return }
        previewItem(at: selected)
    }

    @objc private func removeSelected() {
        let selected = selectedURLs
        guard !selected.isEmpty else { return }
        let removed = StashStore.shared.removeFromStash(selected)
        if let previewURL, removed.contains(where: { $0.originalURL == previewURL }) {
            self.previewURL = nil
            if let panel = QLPreviewPanel.shared(), panel.isVisible { panel.orderOut(nil) }
        }
        reload()
        guard !removed.isEmpty else {
            selectionLabel.stringValue = "Couldn’t remove these items"
            return
        }
        undoItems.append(contentsOf: removed)
        undoButton.isHidden = !undoItems.contains { $0.trashedURL != nil }
        selectionLabel.stringValue = removed.count == selected.count
            ? "Moved \(removed.count) to Trash"
            : "Moved \(removed.count); \(selected.count - removed.count) couldn’t be removed"
    }

    @objc private func undoRemoval() {
        let restored = StashStore.shared.restore(undoItems)
        clearUndo()
        reload()
        selectionLabel.stringValue = restored > 0 ? "Restored \(restored) to Stash" : "Couldn’t restore; check Trash"
    }

    private func clearUndo() {
        undoItems = []
        undoButton.isHidden = true
        updateSelection()
    }

    // MARK: Quick Look

    private func previewItem(at indexPath: IndexPath) {
        guard urls.indices.contains(indexPath.item) else { return }
        previewURL = urls[indexPath.item]
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    // MARK: Debug render

    func previewImage(scale: CGFloat = 2) -> NSImage? {
        reload()
        if ProcessInfo.processInfo.environment["PET_STASH_RENDER_SELECTED"] == "1", !urls.isEmpty {
            collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
            updateSelection()
        }
        contentView?.layoutSubtreeIfNeeded()
        guard let view = contentView else { return nil }
        view.displayIfNeeded()
        let b = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        let image = NSImage(size: b.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Keeps item gestures out of the panel's background drag region. A click selects,
/// a double-click previews, and moving past the threshold remains a file drag.
private final class StashCollectionView: NSCollectionView {
    var onOpen: ((IndexPath) -> Void)?
    private var pressedItem: IndexPath?
    private var pressPoint = NSPoint.zero
    private var moved = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pressPoint = convert(event.locationInWindow, from: nil)
        pressedItem = indexPathForItem(at: pressPoint)
        moved = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= 3 { moved = true }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedItem = pressedItem
        super.mouseUp(with: event)
        defer { pressedItem = nil }
        guard !moved, event.clickCount >= 2, let clickedItem,
              indexPathForItem(at: point) == clickedItem else { return }
        onOpen?(clickedItem)
    }
}

private final class StashItemView: NSCollectionViewItem {
    override func loadView() {
        view = StashItemBackgroundView()
    }

    override var isSelected: Bool {
        didSet { (view as? StashItemBackgroundView)?.selected = isSelected }
    }

    func configure(with url: URL) {
        let icon: NSImage
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let preview = NSImage(contentsOf: url) {
            icon = preview
        } else {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        icon.size = NSSize(width: 54, height: 54)
        let name = FileManager.default.displayName(atPath: url.path)
        let kind = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? "FOLDER" : (url.pathExtension.isEmpty ? "FILE" : url.pathExtension.uppercased())
        (view as? StashItemBackgroundView)?.configure(icon: icon, name: name, kind: kind)
        view.toolTip = url.lastPathComponent
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(name)
    }
}

private final class StashItemBackgroundView: NSView {
    private var fileIcon: NSImage?
    private var fileName = ""
    private var fileKind = ""
    private var hovered = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    var selected = false { didSet { needsDisplay = true } }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(icon: NSImage, name: String, kind: String) {
        fileIcon = icon
        fileName = name
        fileKind = kind
        hovered = false
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        if let hoverArea { addTrackingArea(hoverArea) }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        (selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.42)
                  : NSColor.labelColor.withAlphaComponent(hovered ? 0.12 : 0.06)).setFill()
        tile.fill()
        if let fileIcon {
            let target = CGRect(x: (bounds.width - 56) / 2, y: 48, width: 56, height: 56)
            let scale = min(target.width / max(1, fileIcon.size.width), target.height / max(1, fileIcon.size.height))
            let size = CGSize(width: fileIcon.size.width * scale, height: fileIcon.size.height * scale)
            let fitted = CGRect(x: target.midX - size.width / 2, y: target.midY - size.height / 2,
                                width: size.width, height: size.height)
            fileIcon.draw(in: fitted,
                          from: .zero, operation: .sourceOver, fraction: 1)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        NSAttributedString(string: fileName, attributes: [
            .font: UI.roundedFont(11, .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]).draw(in: CGRect(x: 5, y: 23, width: bounds.width - 10, height: 18))
        NSAttributedString(string: fileKind, attributes: [
            .font: UI.roundedFont(9, .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]).draw(in: CGRect(x: 5, y: 8, width: bounds.width - 10, height: 13))
    }
}

enum StashPreview {
    static func render(to url: URL) {
        let panel = StashPanel()
        guard let image = panel.previewImage(), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
