import AppKit

// MARK: - Popover thumbnail cell

final class PopoverThumbCell: NSView {

    private let imageBox  = NSView()
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")

    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = OPTheme.cardBg.cgColor
        layer?.borderWidth  = 0.5
        layer?.borderColor  = OPTheme.border.cgColor

        imageBox.wantsLayer = true
        imageBox.layer?.cornerRadius    = 7
        imageBox.layer?.masksToBounds   = true
        imageBox.layer?.backgroundColor = OPTheme.appBg.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer   = true
        imageView.layer?.cornerRadius  = 7
        imageView.layer?.masksToBounds = true

        nameLabel.font          = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.textColor     = OPTheme.title
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment     = .center

        sizeLabel.font      = .systemFont(ofSize: 9)
        sizeLabel.textColor = OPTheme.dim
        sizeLabel.alignment = .center

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageBox.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: imageBox.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageBox.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: imageBox.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageBox.trailingAnchor),
        ])

        for v: NSView in [imageBox, nameLabel, sizeLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            imageBox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            imageBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            imageBox.heightAnchor.constraint(equalTo: imageBox.widthAnchor),

            nameLabel.topAnchor.constraint(equalTo: imageBox.bottomAnchor, constant: 4),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),

            sizeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sizeLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])

        // Double-click to download — prevents accidental imports
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.numberOfClicksRequired = 2
        addGestureRecognizer(click)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ file: RecentFile) {
        if let data = file.thumbData, let img = NSImage(data: data) {
            imageView.image = img
            imageView.contentTintColor = nil
            nameLabel.isHidden = true
            sizeLabel.isHidden = true
        } else {
            let sym = file.isImage ? "photo.fill" : file.isVideo ? "film.fill"
                    : file.isAudio ? "music.note" : "doc.fill"
            imageView.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            imageView.contentTintColor = OPTheme.dim
            nameLabel.stringValue = file.name
            sizeLabel.stringValue = formatSize(file.size)
            nameLabel.isHidden = false
            sizeLabel.isHidden = false
        }
    }

    @objc private func tapped() { onClick?() }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = OPTheme.accentTint.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = OPTheme.cardBg.cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self))
    }

    private func formatSize(_ b: Int64) -> String {
        let mb = Double(b) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(b)/1024) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb/1024)
    }
}

// MARK: - Drag-capable popover content view
// Registers as a drop target so files dragged directly onto the open popover are accepted.

final class DraggablePopoverView: NSView {
    var onDragEnter: (() -> Void)?
    var onDragExit:  (() -> Void)?
    var onDrop:      (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { onDragEnter?(); return .copy }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { onDragExit?() }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let urls = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        onDragExit?()
        onDrop?(urls)
        return true
    }
}

// MARK: - Drop zone view (visual overlay only — drag is handled by DraggablePopoverView)

final class PopoverDropZoneView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Quit button (Mac traffic-light red circle)

/// Small circle button that mimics a macOS traffic-light button.
/// Set `baseColor` before adding to a view (default: systemRed).
final class TrafficLightButton: NSButton {

    var baseColor: NSColor = .systemRed {
        didSet { layer?.backgroundColor = baseColor.cgColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered  = false
        title       = ""
        wantsLayer  = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = baseColor.cgColor
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = (baseColor.blended(withFraction: 0.3, of: .white) ?? baseColor).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseColor.cgColor
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = baseColor.darker().cgColor
        super.mouseDown(with: event)
    }
}

private extension NSColor {
    func darker() -> NSColor {
        blended(withFraction: 0.2, of: .black) ?? self
    }
}

// MARK: - Popover view controller

final class MenuBarPopoverViewController: NSViewController {

    // MARK: - Callbacks (wired by MenuBarController)

    var onOpenBrowser:  (() -> Void)?
    var onDownloadFile: ((String) -> Void)?
    var onReconnect:    (() -> Void)?
    /// Called when files are dropped directly onto the popover drop zone.
    var onDrop:         (([URL]) -> Void)?
    weak var popover: NSPopover?

    // MARK: - Private UI refs

    private let statusDot       = NSView()
    private let deviceLabel     = NSTextField(labelWithString: "Searching…")
    private let batteryLabel    = NSTextField(labelWithString: "")
    private let thumbRow        = NSStackView()
    private var thumbCells: [PopoverThumbCell] = []
    private let emptyLabel      = NSTextField(labelWithString: "No recent files yet")
    private let recentSeparator = NSBox()
    private let recentLabel     = NSTextField(labelWithString: "Recent files")
    private let viewAllBtn      = NSButton(title: "View  ›", target: nil, action: nil)

    // Transfer status row (replaces hint label during active transfers)
    private let xferStatusLabel = NSTextField(labelWithString: "")
    private let xferProgressBar = NSProgressIndicator()
    private var xferStack: NSStackView!

    // Stored so checkForUpdates can animate it
    private let versionBtn = NSButton(title: AppVersion.display, target: nil, action: nil)

    // Drop zone overlay (shown when user drags files over the menu bar icon)
    private let dropZone = PopoverDropZoneView()

    // MARK: - Lifecycle

    override func loadView() {
        let v = DraggablePopoverView(frame: NSRect(x: 0, y: 0, width: 310, height: 270))
        v.layer?.backgroundColor = OPTheme.popoverBg.cgColor
        v.onDragEnter = { [weak self] in self?.dropZone.isHidden = false }
        v.onDragExit  = { [weak self] in self?.dropZone.isHidden = true }
        v.onDrop      = { [weak self] urls in self?.onDrop?(urls) }
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        buildDropZone()
    }

    // MARK: - Public API

    func update(deviceName: String?, battery: Int, charging: Bool, recentFiles: [RecentFile]) {
        let connected = deviceName != nil
        if let name = deviceName {
            deviceLabel.stringValue = name
            statusDot.layer?.backgroundColor = OPTheme.online.cgColor
        } else {
            deviceLabel.stringValue = "Searching for device…"
            statusDot.layer?.backgroundColor = OPTheme.offline.cgColor
        }
        let battIcon = charging ? "⚡" : battery > 70 ? "🔋" : battery > 30 ? "🪫" : "🔴"
        batteryLabel.stringValue = battery >= 0 ? "\(battIcon) \(battery)%" : ""

        // Hide the entire recent-files section when not connected — never show stale data.
        recentSeparator.isHidden = !connected
        recentLabel.isHidden     = !connected
        viewAllBtn.isHidden      = !connected
        thumbRow.isHidden        = !connected
        emptyLabel.isHidden      = true   // managed by updateThumbnails when shown
        xferStack?.isHidden      = !connected

        if connected { updateThumbnails(recentFiles) }
    }

    /// Shows/hides the drag-drop overlay. Called by MenuBarController on drag enter/exit.
    func setDropActive(_ active: Bool) {
        dropZone.isHidden = !active
    }

    /// Call during a transfer to show progress. Pass nil/nil to return to hint text.
    func updateTransfer(progress: Double?, status: String?) {
        if let progress, let status {
            xferProgressBar.isHidden    = false
            xferProgressBar.doubleValue = progress
            xferStatusLabel.stringValue = status
        } else {
            xferProgressBar.isHidden    = true
            xferStatusLabel.stringValue = "Double-click to download · Drag to upload"
        }
    }

    // MARK: - Build layout

    private func buildLayout() {
        // ── Header ────────────────────────────────────────────────────
        let headerBar = makeHeaderBar()

        // ── Status dot + device name ──────────────────────────────────
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4.5
        statusDot.layer?.backgroundColor = OPTheme.offline.cgColor

        deviceLabel.font      = .systemFont(ofSize: 14, weight: .semibold)
        deviceLabel.textColor = OPTheme.title
        deviceLabel.lineBreakMode = .byTruncatingTail

        batteryLabel.font      = .systemFont(ofSize: 11)
        batteryLabel.textColor = OPTheme.body

        // ── Divider ───────────────────────────────────────────────────
        recentSeparator.boxType = .separator

        // ── Recent files header ───────────────────────────────────────
        recentLabel.font      = .systemFont(ofSize: 12, weight: .semibold)
        recentLabel.textColor = OPTheme.title

        viewAllBtn.target         = self; viewAllBtn.action = #selector(openBrowser)
        viewAllBtn.isBordered       = false
        viewAllBtn.font             = .systemFont(ofSize: 12)
        viewAllBtn.contentTintColor = OPTheme.accent

        // ── Thumbnails ────────────────────────────────────────────────
        thumbRow.orientation  = .horizontal
        thumbRow.distribution = .fillEqually
        thumbRow.spacing      = 8
        thumbCells = (0..<3).map { _ in PopoverThumbCell() }
        thumbCells.forEach { thumbRow.addArrangedSubview($0) }

        emptyLabel.font      = .systemFont(ofSize: 11)
        emptyLabel.textColor = OPTheme.dim
        emptyLabel.alignment = .center
        emptyLabel.isHidden  = true

        // ── Footer: dual-purpose row (hint text ↔ transfer status + cancel) ──
        xferStatusLabel.font      = .systemFont(ofSize: 10)
        xferStatusLabel.textColor = OPTheme.dim
        xferStatusLabel.alignment = .left
        xferStatusLabel.stringValue = "Double-click to download · Drag to upload"
        xferStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        xferProgressBar.style = .bar
        xferProgressBar.isIndeterminate = false
        xferProgressBar.minValue = 0; xferProgressBar.maxValue = 1
        xferProgressBar.isHidden = true
        xferProgressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        xferStack = NSStackView(views: [xferStatusLabel, xferProgressBar])
        xferStack.orientation  = .horizontal
        xferStack.spacing      = 8
        xferStack.distribution = .fill

        // ── Assemble ──────────────────────────────────────────────────
        let all: [NSView] = [headerBar, statusDot, deviceLabel, batteryLabel,
                             recentSeparator, recentLabel, viewAllBtn, thumbRow, emptyLabel,
                             xferStack]
        all.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            headerBar.topAnchor.constraint(equalTo: view.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 46),

            // Device row
            statusDot.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusDot.topAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: 14),
            statusDot.widthAnchor.constraint(equalToConstant: 9),
            statusDot.heightAnchor.constraint(equalToConstant: 9),

            deviceLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 7),
            deviceLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),
            deviceLabel.trailingAnchor.constraint(lessThanOrEqualTo: batteryLabel.leadingAnchor, constant: -8),

            batteryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            batteryLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),

            // Separator
            recentSeparator.topAnchor.constraint(equalTo: statusDot.bottomAnchor, constant: 12),
            recentSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            recentSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            // Recent files header
            recentLabel.topAnchor.constraint(equalTo: recentSeparator.bottomAnchor, constant: 10),
            recentLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            viewAllBtn.centerYAnchor.constraint(equalTo: recentLabel.centerYAnchor),
            viewAllBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),

            // Thumbnails
            thumbRow.topAnchor.constraint(equalTo: recentLabel.bottomAnchor, constant: 8),
            thumbRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            thumbRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            thumbRow.heightAnchor.constraint(equalToConstant: 118),

            emptyLabel.centerXAnchor.constraint(equalTo: thumbRow.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: thumbRow.centerYAnchor),

            // Footer (hint text / transfer status)
            xferStack.topAnchor.constraint(equalTo: thumbRow.bottomAnchor, constant: 10),
            xferStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            xferStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            xferStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Header bar (O+Connect style)

    private func makeHeaderBar() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = OPTheme.popoverBg.cgColor
        // Bottom border
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = OPTheme.divider.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)

        // Mac traffic-light style buttons: red = quit, yellow = reconnect
        let quitCircle = TrafficLightButton()
        quitCircle.baseColor = .systemRed
        quitCircle.target = NSApp
        quitCircle.action = #selector(NSApplication.terminate(_:))
        quitCircle.toolTip = "Quit Android Connect"

        let reconnectCircle = TrafficLightButton()
        reconnectCircle.baseColor = NSColor(red: 1.0, green: 0.73, blue: 0.0, alpha: 1)
        reconnectCircle.target = self
        reconnectCircle.action = #selector(reconnect)
        reconnectCircle.toolTip = "Reconnect — drop existing connection and scan for device"

        let title = NSTextField(labelWithString: "Android Connect by Pericardium.7")
        title.font      = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = OPTheme.title

        // Version button — replaces the redundant macwindow icon.
        // "View ›" already opens the full browser; this button checks for updates.
        versionBtn.target = self; versionBtn.action = #selector(checkForUpdates)
        versionBtn.isBordered  = false
        versionBtn.font        = .systemFont(ofSize: 11, weight: .medium)
        versionBtn.contentTintColor = OPTheme.dim
        versionBtn.toolTip     = "Check for updates"

        for v: NSView in [quitCircle, reconnectCircle, title, versionBtn] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        NSLayoutConstraint.activate([
            quitCircle.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            quitCircle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            quitCircle.widthAnchor.constraint(equalToConstant: 12),
            quitCircle.heightAnchor.constraint(equalToConstant: 12),

            reconnectCircle.leadingAnchor.constraint(equalTo: quitCircle.trailingAnchor, constant: 7),
            reconnectCircle.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            reconnectCircle.widthAnchor.constraint(equalToConstant: 12),
            reconnectCircle.heightAnchor.constraint(equalToConstant: 12),

            title.leadingAnchor.constraint(equalTo: reconnectCircle.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            versionBtn.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            versionBtn.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        return bar
    }

    // MARK: - Drop zone overlay

    private func buildDropZone() {
        dropZone.layer?.backgroundColor = OPTheme.popoverBg.cgColor
        dropZone.layer?.cornerRadius    = 0
        dropZone.isHidden = true
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dropZone)
        NSLayoutConstraint.activate([
            dropZone.topAnchor.constraint(equalTo: view.topAnchor),
            dropZone.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dropZone.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dropZone.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Dashed border box
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius    = 16
        box.layer?.backgroundColor = OPTheme.accentTint.cgColor
        box.layer?.borderWidth = 2
        box.layer?.borderColor = OPTheme.accent.cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let phoneIcon = NSImageView()
        phoneIcon.image = NSImage(systemSymbolName: "iphone.and.arrow.forward",
                                  accessibilityDescription: nil)
        phoneIcon.contentTintColor = OPTheme.accent
        phoneIcon.translatesAutoresizingMaskIntoConstraints = false

        let dropLabel = NSTextField(labelWithString: "Drop files to send to phone")
        dropLabel.font      = .systemFont(ofSize: 13, weight: .semibold)
        dropLabel.textColor = OPTheme.accent
        dropLabel.alignment = .center
        dropLabel.translatesAutoresizingMaskIntoConstraints = false

        let subLabel = NSTextField(labelWithString: "Files will be saved to /sdcard/AndroidConnect")
        subLabel.font      = .systemFont(ofSize: 10)
        subLabel.textColor = OPTheme.body
        subLabel.alignment = .center
        subLabel.translatesAutoresizingMaskIntoConstraints = false

        dropZone.addSubview(box)
        box.addSubview(phoneIcon)
        box.addSubview(dropLabel)
        box.addSubview(subLabel)

        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: dropZone.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: dropZone.centerYAnchor),
            box.widthAnchor.constraint(equalTo: dropZone.widthAnchor, constant: -32),
            box.heightAnchor.constraint(equalToConstant: 160),

            phoneIcon.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            phoneIcon.topAnchor.constraint(equalTo: box.topAnchor, constant: 28),
            phoneIcon.widthAnchor.constraint(equalToConstant: 40),
            phoneIcon.heightAnchor.constraint(equalToConstant: 40),

            dropLabel.topAnchor.constraint(equalTo: phoneIcon.bottomAnchor, constant: 12),
            dropLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            dropLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),

            subLabel.topAnchor.constraint(equalTo: dropLabel.bottomAnchor, constant: 6),
            subLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            subLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
        ])
    }

    // MARK: - Thumbnails

    private func updateThumbnails(_ files: [RecentFile]) {
        let top = Array(files.prefix(3))
        let empty = top.isEmpty
        emptyLabel.isHidden = !empty
        thumbRow.isHidden   = empty

        for (i, cell) in thumbCells.enumerated() {
            if i < top.count {
                cell.isHidden = false
                cell.configure(top[i])
                let path = top[i].path
                cell.onClick = { [weak self] in self?.onDownloadFile?(path) }
            } else {
                cell.isHidden = true
            }
        }
    }

    // MARK: - Actions

    @objc private func openBrowser() { onOpenBrowser?() }

    @objc private func checkForUpdates() {
        // Immediate feedback — user sees "Checking…" in the button right away.
        // Popover stays open during the network fetch so there's no confusing gap.
        versionBtn.title     = "Checking…"
        versionBtn.isEnabled = false

        UpdateChecker.shared.checkForUpdates {
            // Restore button, then close popover just before the result alert appears.
            self.versionBtn.title     = AppVersion.display
            self.versionBtn.isEnabled = true
            self.popover?.performClose(nil)
        }
    }

    @objc private func reconnect() {
        onReconnect?()
        // Keep popover open — status dot will flip to "Searching…" so user sees it working
    }
}
