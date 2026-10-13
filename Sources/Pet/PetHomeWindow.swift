import AppKit

/// A small home for Pet's color, size and app-ring choices.
final class PetHomeWindowController: NSWindowController, NSWindowDelegate {
    private weak var petController: PetController?
    private let room = PetRoomView()
    private let sizeSlider = NSSlider(value: 1, minValue: 0.85, maxValue: 1.15, target: nil, action: nil)
    private let sizeValue = NSTextField(labelWithString: "100%")
    private let appIcons = AppIconStrip()
    private let appModeControl = NSSegmentedControl(labels: ["Pinned", "Recent 6"], trackingMode: .selectOne, target: nil, action: nil)
    private let editAppsButton = NSButton(title: "Edit Apps…", target: nil, action: nil)
    private var skinButtons: [SkinButton] = []
    private var previousApp: NSRunningApplication?

    init(controller: PetController) {
        petController = controller
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Pet"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 740, height: 490)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        guard let window else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        if !window.isVisible {
            window.center()
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        room.pause()
        if let previousApp, previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: previousApp) }
            previousApp.activate(options: [])
        }
        previousApp = nil
    }

    func windowDidBecomeKey(_ notification: Notification) { room.resume() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = makeHeader()
        let left = makePreviewColumn()
        let right = makeSettingsColumn()
        let divider = NSBox()
        divider.boxType = .separator
        for view in [header, left, right, divider] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            header.heightAnchor.constraint(equalToConstant: 48),

            left.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            left.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            left.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            left.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            divider.topAnchor.constraint(equalTo: left.topAnchor),
            divider.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 18),
            divider.widthAnchor.constraint(equalToConstant: 1),

            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 18),
            right.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            right.bottomAnchor.constraint(lessThanOrEqualTo: left.bottomAnchor),
            right.widthAnchor.constraint(equalToConstant: 390),
        ])
    }

    private func makeHeader() -> NSView {
        let view = NSView()
        let title = NSTextField(labelWithString: "Pet")
        title.font = UI.roundedFont(28, .bold)
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    private func makePreviewColumn() -> NSView {
        room.layer?.cornerRadius = 14
        return room
    }

    private func makeSizeSection() -> NSView {
        let card = CardView()
        let sizeTitle = NSTextField(labelWithString: "Size")
        sizeTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let small = NSTextField(labelWithString: "Small")
        let normal = NSTextField(labelWithString: "Default")
        let large = NSTextField(labelWithString: "Large")
        for label in [small, normal, large] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
        sizeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeValue.textColor = .secondaryLabelColor

        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.isContinuous = true
        sizeSlider.numberOfTickMarks = 3
        sizeSlider.allowsTickMarkValuesOnly = false

        let labelRow = NSView()
        for label in [small, normal, large] { label.translatesAutoresizingMaskIntoConstraints = false; labelRow.addSubview(label) }
        NSLayoutConstraint.activate([
            small.leadingAnchor.constraint(equalTo: labelRow.leadingAnchor),
            normal.centerXAnchor.constraint(equalTo: labelRow.centerXAnchor),
            large.trailingAnchor.constraint(equalTo: labelRow.trailingAnchor),
            small.centerYAnchor.constraint(equalTo: labelRow.centerYAnchor),
            normal.centerYAnchor.constraint(equalTo: labelRow.centerYAnchor),
            large.centerYAnchor.constraint(equalTo: labelRow.centerYAnchor),
        ])

        let titleRow = NSView()
        for item in [sizeTitle, sizeValue] { item.translatesAutoresizingMaskIntoConstraints = false; titleRow.addSubview(item) }
        NSLayoutConstraint.activate([
            sizeTitle.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            sizeTitle.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            sizeValue.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            sizeValue.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
        ])

        for item in [titleRow, sizeSlider, labelRow] { item.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(item) }
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            titleRow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleRow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            titleRow.heightAnchor.constraint(equalToConstant: 18),
            sizeSlider.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 7),
            sizeSlider.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            sizeSlider.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            labelRow.topAnchor.constraint(equalTo: sizeSlider.bottomAnchor, constant: 3),
            labelRow.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            labelRow.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            labelRow.heightAnchor.constraint(equalToConstant: 16),
        ])
        return card
    }

    private func makeSettingsColumn() -> NSView {
        let color = makeSkinSection()
        let size = makeSizeSection()
        let apps = makeAppsSection()
        let stack = NSStackView(views: [color, size, apps])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.distribution = .fill
        color.heightAnchor.constraint(equalToConstant: 146).isActive = true
        size.heightAnchor.constraint(equalToConstant: 98).isActive = true
        apps.heightAnchor.constraint(equalToConstant: 122).isActive = true
        return stack
    }

    private func makeSkinSection() -> NSView {
        let card = CardView()
        let title = sectionTitle("Color")
        title.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(title)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.distribution = .fillEqually
        for (index, coat) in Coat.allCases.enumerated() {
            let button = SkinButton(coat: coat)
            button.tag = index
            button.target = self
            button.action = #selector(skinPicked(_:))
            skinButtons.append(button)
            row.addArrangedSubview(button)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    private func makeAppsSection() -> NSView {
        let card = CardView()
        let title = sectionTitle("Apps")
        editAppsButton.target = self
        editAppsButton.action = #selector(editApps)
        editAppsButton.bezelStyle = .rounded
        editAppsButton.controlSize = .small
        appModeControl.target = self
        appModeControl.action = #selector(appModeChanged)
        appModeControl.controlSize = .small
        appModeControl.segmentStyle = .rounded
        appModeControl.setAccessibilityLabel("Apps shown in Pet's ring")
        for item in [title, editAppsButton, appModeControl, appIcons] { item.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(item) }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            editAppsButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            editAppsButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            appModeControl.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            appModeControl.trailingAnchor.constraint(equalTo: editAppsButton.trailingAnchor),
            appModeControl.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            appIcons.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            appIcons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            appIcons.topAnchor.constraint(equalTo: appModeControl.bottomAnchor, constant: 5),
            appIcons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    private func sectionTitle(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        return label
    }

    private func refresh() {
        guard let controller = petController else { return }
        room.update(coat: controller.currentCoat, size: controller.petScale)
        sizeSlider.doubleValue = Double(controller.petScale)
        sizeValue.stringValue = "\(Int((controller.petScale * 100).rounded()))%"
        for (index, button) in skinButtons.enumerated() {
            button.setSelected(Coat.allCases[index] == controller.currentCoat)
        }
        refreshApps()
    }

    func refreshApps() {
        guard let controller = petController else { return }
        let recent = controller.currentAppRingMode == .recent
        appModeControl.selectedSegment = recent ? 1 : 0
        editAppsButton.isHidden = recent
        appIcons.reload(urls: controller.ringAppURLs,
                        emptyMessage: recent ? "Switch between apps to fill this list" : "No apps yet")
    }

    @objc private func skinPicked(_ sender: SkinButton) {
        guard Coat.allCases.indices.contains(sender.tag) else { return }
        petController?.setCoat(Coat.allCases[sender.tag])
        refresh()
    }

    @objc private func sizeChanged() {
        let value = CGFloat(sizeSlider.doubleValue)
        petController?.setPetScale(value)
        sizeValue.stringValue = "\(Int((value * 100).rounded()))%"
        room.update(coat: petController?.currentCoat ?? .hojiro, size: value)
    }

    @objc private func editApps() {
        petController?.showManageApps { [weak self] in self?.refresh() }
    }

    @objc private func appModeChanged() {
        petController?.setAppRingMode(appModeControl.selectedSegment == 1 ? .recent : .pinned)
        refreshApps()
    }
}

private final class CardView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .contentBackground
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.28).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class SkinButton: NSButton {
    let coat: Coat

    init(coat: Coat) {
        self.coat = coat
        super.init(frame: .zero)
        title = PetHomeWindowController.shortName(for: coat)
        image = PetThumbnail.image(for: coat, size: NSSize(width: 44, height: 48))
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 9.5, weight: .medium)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        setAccessibilityLabel("\(title) color")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ selected: Bool) {
        state = selected ? .on : .off
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = selected ? 1.5 : 0
        layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : nil
        contentTintColor = selected ? .controlAccentColor : .labelColor
    }
}

private extension PetHomeWindowController {
    static func shortName(for coat: Coat) -> String {
        switch coat {
        case .sand: return "Sand"
        case .hojiro: return "Blue"
        case .deep: return "Navy"
        case .sakura: return "Coral"
        case .mint: return "Forest"
        case .charcoal: return "Charcoal"
        }
    }
}

private enum PetThumbnail {
    private static var cache: [Coat: NSImage] = [:]

    static func image(for coat: Coat, size: NSSize) -> NSImage {
        if let cached = cache[coat] { return cached }
        let view = PetView(frame: NSRect(origin: .zero, size: PetGeometry.viewSize))
        var pose = PetPose()
        pose.coat = coat
        pose.shadow = 1
        view.pose = pose
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return NSImage(size: size) }
        view.cacheDisplay(in: view.bounds, to: rep)
        let source = NSImage(size: view.bounds.size)
        source.addRepresentation(rep)
        let output = NSImage(size: size)
        output.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size), from: view.bounds, operation: .sourceOver, fraction: 1)
        output.unlockFocus()
        cache[coat] = output
        return output
    }
}

private final class AppIconStrip: NSView {
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload(urls: [URL], emptyMessage: String = "No apps yet") {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for url in urls.prefix(7) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 34, height: 34)
            let image = NSImageView(image: icon)
            image.toolTip = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 34), image.heightAnchor.constraint(equalToConstant: 34)])
            stack.addArrangedSubview(image)
        }
        if urls.isEmpty {
            let label = NSTextField(labelWithString: emptyMessage)
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12)
            stack.addArrangedSubview(label)
        }
    }
}

private final class PetRoomView: NSView {
    private let pet = PetView(frame: NSRect(origin: .zero, size: PetGeometry.viewSize))
    private var timer: Timer?
    private var coat: Coat = .hojiro
    private var size: CGFloat = 1
    private var phase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        addSubview(pet)
        resume()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    override func layout() {
        super.layout()
        pet.frame = NSRect(x: bounds.midX - PetGeometry.viewSize.width / 2,
                           y: bounds.midY - PetGeometry.viewSize.height / 2,
                           width: PetGeometry.viewSize.width,
                           height: PetGeometry.viewSize.height)
    }

    func update(coat: Coat, size: CGFloat) {
        self.coat = coat
        self.size = size
        updatePose()
    }

    func pause() { timer?.invalidate(); timer = nil }

    func resume() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.05
            self.updatePose()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updatePose() {
        var pose = PetPose()
        pose.coat = coat
        pose.displayScale = size
        pose.shadow = 1
        pose.bob = 1.6 * sin(phase * 1.7)
        let blinking = Int(phase * 10) % 83 == 0
        pose.eyeStyle = blinking ? .closed : .open
        pose.eyeOpen = blinking ? 0 : 1
        pose.time = phase
        pet.pose = pose
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = dark ? NSColor(red: 0.19, green: 0.22, blue: 0.27, alpha: 1) : NSColor(red: 0.94, green: 0.97, blue: 0.99, alpha: 1)
        let bottom = dark ? NSColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1) : NSColor(red: 0.89, green: 0.94, blue: 0.98, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: 90)
    }
}

enum HomePreview {
    static func render(to url: URL) {
        let controller = PetController()
        let home = PetHomeWindowController(controller: controller)
        guard let view = home.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
