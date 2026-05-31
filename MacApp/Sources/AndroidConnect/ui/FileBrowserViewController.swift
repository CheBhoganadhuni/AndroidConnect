import AppKit
import QuartzCore

// MARK: - Thumbnail collection item

private let thumbItemID = NSUserInterfaceItemIdentifier("ThumbItem")

final class FileThumbnailItem: NSCollectionViewItem {

    let thumbView  = NSImageView()
    let nameLabel  = NSTextField(labelWithString: "")
    let sizeLabel  = NSTextField(labelWithString: "")
    private let bg = NSView()

    private var currentPath: String?
    private var pendingLoad: DispatchWorkItem?

    override func loadView() {
        let v = NSView()
        view = v
        v.wantsLayer = true

        bg.wantsLayer = true
        bg.layer?.cornerRadius  = 10
        bg.layer?.borderWidth   = 0.5
        bg.layer?.borderColor   = NSColor(white: 0.5, alpha: 0.15).cgColor

        thumbView.imageScaling  = .scaleProportionallyUpOrDown
        thumbView.wantsLayer    = true
        thumbView.layer?.cornerRadius    = 8
        thumbView.layer?.masksToBounds   = true

        nameLabel.font          = .systemFont(ofSize: 11)
        nameLabel.textColor     = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.alignment     = .center

        sizeLabel.font      = .systemFont(ofSize: 10)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .center

        for sub: NSView in [thumbView, nameLabel, sizeLabel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(sub)
        }
        bg.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(bg)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            bg.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
            bg.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            bg.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),

            thumbView.topAnchor.constraint(equalTo: bg.topAnchor, constant: 8),
            thumbView.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            thumbView.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            thumbView.heightAnchor.constraint(equalTo: thumbView.widthAnchor),

            nameLabel.topAnchor.constraint(equalTo: thumbView.bottomAnchor, constant: 5),
            nameLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),

            sizeLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            sizeLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            sizeLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            sizeLabel.bottomAnchor.constraint(lessThanOrEqualTo: bg.bottomAnchor, constant: -6),
        ])
    }

    override var isSelected: Bool {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bg.layer?.backgroundColor = isSelected
                ? OPTheme.accentTint.cgColor
                : OPTheme.cardBg.cgColor
            bg.layer?.borderColor = isSelected
                ? OPTheme.accent.withAlphaComponent(0.5).cgColor
                : OPTheme.border.cgColor
            CATransaction.commit()
        }
    }

    func configure(_ item: FileItem, client: SocketClient) {
        // Cancel any in-flight debounce from a previous item (cell reuse guard)
        pendingLoad?.cancel()
        pendingLoad = nil

        nameLabel.stringValue = item.name
        sizeLabel.stringValue = item.isDir ? "Folder" : formatSize(item.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bg.layer?.backgroundColor = OPTheme.cardBg.cgColor
        CATransaction.commit()

        let sym = item.isDir   ? "folder.fill"
                : isImage(item) ? "photo.fill"
                : isVideo(item) ? "film.fill"
                : isAudio(item) ? "music.note"
                : "doc.fill"
        thumbView.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        thumbView.contentTintColor = item.isDir ? .systemYellow : .tertiaryLabelColor

        guard !item.isDir else { currentPath = nil; return }

        let path = item.path
        currentPath = path

        // Serve from cache instantly — no debounce needed for cache hits
        if let cached = client.cachedThumbnail(for: path) {
            thumbView.image = cached
            thumbView.contentTintColor = nil
            return
        }

        // 80ms debounce: fast scroll recycles the cell before this fires → cancelled, no request sent.
        // Only cells visible for ≥80ms actually hit the network.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentPath == path else { return }
            client.requestThumbnail(path: path) { [weak self] img in
                guard let self, self.currentPath == path, let img else { return }
                self.thumbView.image = img
                self.thumbView.contentTintColor = nil
            }
        }
        pendingLoad = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func isImage(_ i: FileItem) -> Bool {
        ["jpg","jpeg","png","gif","heic","heif","webp","bmp"].contains(ext(i))
    }
    private func isVideo(_ i: FileItem) -> Bool {
        ["mp4","mov","mkv","avi","wmv","flv","3gp","webm"].contains(ext(i))
    }
    private func isAudio(_ i: FileItem) -> Bool {
        ["mp3","m4a","flac","wav","ogg","aac","wma","opus"].contains(ext(i))
    }
    private func ext(_ i: FileItem) -> String {
        (i.name as NSString).pathExtension.lowercased()
    }
    private func formatSize(_ b: Int64) -> String {
        let mb = Double(b) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(b)/1024) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb/1024)
    }
}

// MARK: - FileBrowserViewController

final class FileBrowserViewController: NSViewController {

    // MARK: - Dependencies / state

    let client: SocketClient
    private var mode: BrowserMode = .directory(path: "/sdcard")
    private var items: [FileItem] = []
    private var pathStack: [(mode: BrowserMode, label: String)] = []
    private var isGridView  = true
    private var isRefreshing = false

    /// Snapshot of selection saved BEFORE a click clears it — used so double-clicking
    /// any item in a multi-selection still downloads all selected items.
    private var savedCollectionSelection: Set<IndexPath> = []
    private var savedTableSelection: IndexSet = []

    // MARK: - Toolbar UI

    private let backBtn      = NSButton(title: "", target: nil, action: nil)
    private let pathLabel    = NSTextField(labelWithString: "/sdcard")
    private let storageLabel = NSTextField(labelWithString: "")
    private let refreshBtn   = NSButton(title: "", target: nil, action: nil)
    private let gridBtn      = NSButton(title: "", target: nil, action: nil)
    private let listBtn      = NSButton(title: "", target: nil, action: nil)
    private let transferBtn  = NSButton(title: "⬆ Transfer", target: nil, action: nil)

    // MARK: - Grid view (NSCollectionView)

    private let collectionView  = NSCollectionView()
    private let collectionScroll = NSScrollView()

    // MARK: - List view (NSTableView)

    private let tableView    = NSTableView()
    private let tableScroll  = NSScrollView()

    // MARK: - Bottom bar

    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Ready")

    // MARK: - Init

    init(client: SocketClient) {
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = OPTheme.appBg.cgColor
        view = v
        buildToolbar()
        buildCollectionView()
        buildTableView()
        buildBottomBar()
        applyLayout()
        applyViewMode()
    }

    // MARK: - Public API (called by MainWindowController / MenuBarController)

    /// Called by MainWindowController when storage info arrives from the device.
    func updateStorage(_ info: StorageInfo) {
        storageLabel.stringValue = "\(info.usedGB) / \(info.totalGB)"
        storageLabel.isHidden = false
    }

    func applyMode(_ newMode: BrowserMode) {
        if mode != newMode {
            pathStack.removeAll()
        }
        mode = newMode
        pathLabel.stringValue = newMode.displayTitle
        backBtn.isEnabled = false
        load(mode: newMode)
    }

    func pushDirectory(_ path: String) {
        pathStack.append((mode: mode, label: pathLabel.stringValue))
        mode = .directory(path: path)
        pathLabel.stringValue = path.components(separatedBy: "/").last ?? path
        backBtn.isEnabled = true
        load(mode: mode)
    }

    // MARK: - Build

    private func buildToolbar() {
        // Back
        backBtn.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backBtn.isBordered = false
        backBtn.isEnabled  = false
        backBtn.target = self; backBtn.action = #selector(goBack)
        backBtn.contentTintColor = .secondaryLabelColor

        // Path label
        pathLabel.font          = .systemFont(ofSize: 13, weight: .medium)
        pathLabel.textColor     = .labelColor
        pathLabel.lineBreakMode = .byTruncatingHead

        // Storage info (populated once device reports it)
        storageLabel.font      = .systemFont(ofSize: 11)
        storageLabel.textColor = OPTheme.dim
        storageLabel.isHidden  = true

        // Refresh — layer needed for spin animation
        refreshBtn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refreshBtn.isBordered  = false
        refreshBtn.wantsLayer  = true
        refreshBtn.target = self; refreshBtn.action = #selector(refresh)
        refreshBtn.toolTip = "Refresh"

        // Grid / List toggles
        gridBtn.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid")
        gridBtn.isBordered = false
        gridBtn.target = self; gridBtn.action = #selector(showGrid)
        gridBtn.contentTintColor = .controlAccentColor

        listBtn.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "List")
        listBtn.isBordered = false
        listBtn.target = self; listBtn.action = #selector(showList)
        listBtn.contentTintColor = .secondaryLabelColor

        // Transfer — outlined style
        transferBtn.bezelStyle = .rounded
        transferBtn.font       = .systemFont(ofSize: 12, weight: .medium)
        transferBtn.target     = self; transferBtn.action = #selector(transferFiles)
        transferBtn.contentTintColor = OPTheme.accent

    }

    private func buildCollectionView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize       = NSSize(width: 130, height: 158)
        layout.sectionInset   = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing      = 10
        collectionView.collectionViewLayout = layout
        collectionView.register(FileThumbnailItem.self, forItemWithIdentifier: thumbItemID)
        collectionView.dataSource    = self
        collectionView.delegate      = self
        collectionView.isSelectable  = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        // Double-click via gesture (NSCollectionView has no doubleAction property)
        let dblClick = NSClickGestureRecognizer(target: self, action: #selector(collectionDoubleClick))
        dblClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(dblClick)

        collectionScroll.documentView     = collectionView
        collectionScroll.hasVerticalScroller = true
        collectionScroll.autohidesScrollers  = true
        collectionScroll.borderType       = .noBorder
        collectionScroll.backgroundColor  = .clear

        // Right-click menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Download to Mac", action: #selector(downloadSelected), keyEquivalent: ""))
        menu.items.first?.target = self
        collectionView.menu = menu
    }

    private func buildTableView() {
        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = "Name"; nameCol.width = 340; nameCol.minWidth = 200

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = "Size"; sizeCol.width = 90

        let modCol = NSTableColumn(identifier: .init("modified"))
        modCol.title = "Modified"; modCol.width = 140

        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(sizeCol)
        tableView.addTableColumn(modCol)
        tableView.delegate   = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(tableDoubleClick)
        tableView.target       = self
        tableView.rowHeight    = 28
        tableView.gridStyleMask = .solidHorizontalGridLineMask
        tableView.gridColor    = NSColor(white: 0.5, alpha: 0.1)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Download to Mac", action: #selector(downloadSelected), keyEquivalent: ""))
        menu.items.first?.target = self
        tableView.menu = menu

        tableScroll.documentView    = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers  = true
        tableScroll.borderType      = .noBorder
    }

    private func buildBottomBar() {
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.isHidden = true

        statusLabel.font      = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
    }

    private func applyLayout() {
        let toolbarView = NSView()
        toolbarView.wantsLayer = true
        toolbarView.layer?.backgroundColor = OPTheme.toolbarBg.cgColor
        toolbarView.layer?.borderColor     = OPTheme.border.cgColor
        toolbarView.layer?.borderWidth     = 0.5

        let bottomView = NSView()
        bottomView.wantsLayer = true
        bottomView.layer?.backgroundColor = OPTheme.toolbarBg.cgColor

        let viewToggle = NSStackView(views: [gridBtn, listBtn])
        viewToggle.spacing = 4
        viewToggle.orientation = .horizontal

        let toolbarBtns = NSStackView(views: [storageLabel, refreshBtn, viewToggle, transferBtn])
        toolbarBtns.spacing = 10
        toolbarBtns.orientation = .horizontal

        let views: [NSView] = [backBtn, pathLabel, toolbarBtns]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            toolbarView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            backBtn.leadingAnchor.constraint(equalTo: toolbarView.leadingAnchor, constant: 12),
            backBtn.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            backBtn.widthAnchor.constraint(equalToConstant: 28),

            pathLabel.leadingAnchor.constraint(equalTo: backBtn.trailingAnchor, constant: 6),
            pathLabel.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: toolbarBtns.leadingAnchor, constant: -8),

            toolbarBtns.trailingAnchor.constraint(equalTo: toolbarView.trailingAnchor, constant: -14),
            toolbarBtns.centerYAnchor.constraint(equalTo: toolbarView.centerYAnchor),
        ])

        for v: NSView in [statusLabel, progressBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottomView.addSubview(v)
        }
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: bottomView.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 12),
            progressBar.trailingAnchor.constraint(equalTo: bottomView.trailingAnchor, constant: -14),
            progressBar.centerYAnchor.constraint(equalTo: bottomView.centerYAnchor),
        ])

        for v: NSView in [toolbarView, collectionScroll, tableScroll, bottomView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: 44),

            collectionScroll.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            collectionScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionScroll.bottomAnchor.constraint(equalTo: bottomView.topAnchor),

            tableScroll.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: bottomView.topAnchor),

            bottomView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomView.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func applyViewMode() {
        collectionScroll.isHidden = !isGridView
        tableScroll.isHidden      =  isGridView
        gridBtn.contentTintColor  = isGridView ? .controlAccentColor : .secondaryLabelColor
        listBtn.contentTintColor  = isGridView ? .secondaryLabelColor : .controlAccentColor
    }

    // MARK: - Load

    private func load(mode: BrowserMode) {
        statusLabel.stringValue = "Loading…"
        switch mode {
        case .directory(let path):  client.listDirectory(path)
        case .recent:               client.requestRecentFiles(limit: 100)
        case .byType(let t):        client.getFilesByType(t)
        case .bySource(let s):      client.getFilesBySource(s)
        }
    }

    // MARK: - Actions

    @objc private func goBack() {
        guard let prev = pathStack.popLast() else { return }
        mode = prev.mode
        pathLabel.stringValue = prev.label
        backBtn.isEnabled = !pathStack.isEmpty
        load(mode: mode)
    }

    @objc private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshBtn.isEnabled = false
        statusLabel.stringValue = "Refreshing…"

        // Spin the refresh icon clockwise while waiting
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue  = 0
        spin.toValue    = -(CGFloat.pi * 2)
        spin.duration   = 0.7
        spin.repeatCount = .infinity
        refreshBtn.layer?.add(spin, forKey: "spin")

        load(mode: mode)
    }

    private func stopRefreshSpinner() {
        guard isRefreshing else { return }
        isRefreshing = false
        refreshBtn.layer?.removeAnimation(forKey: "spin")
        refreshBtn.isEnabled = true
    }

    @objc private func showGrid() {
        isGridView = true; applyViewMode()
    }

    @objc private func showList() {
        isGridView = false; applyViewMode()
    }

    @objc private func transferFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories    = false
        panel.prompt = "Send to Phone"
        panel.begin { [weak self] r in
            guard r == .OK, let self else { return }
            let destPath = self.currentDirectoryPath()
            for url in panel.urls { self.client.uploadFile(url: url, toDir: destPath) }
        }
    }

    // Right-click "Download to Mac" — only downloads explicitly selected files, never all
    @objc private func downloadSelected() {
        selectedPaths().forEach { client.downloadFile(path: $0) }
    }

    @objc private func collectionDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let loc = gesture.location(in: collectionView)
        guard let ip = collectionView.indexPathForItem(at: loc), ip.item < items.count else { return }
        let item = items[ip.item]
        if item.isDir {
            pushDirectory(item.path)
        } else {
            // The first click of the double-click clears multi-selection before this fires.
            // savedCollectionSelection holds what was selected just before that happened.
            // If the clicked item was part of that saved multi-selection, download all of them.
            let useSelection = savedCollectionSelection.contains(ip) && savedCollectionSelection.count > 1
                ? savedCollectionSelection
                : collectionView.selectionIndexPaths
            let paths = useSelection.sorted()
                .compactMap { items[safe: $0.item] }
                .filter { !$0.isDir }
                .map { $0.path }
            (paths.isEmpty ? [item.path] : paths).forEach { client.downloadFile(path: $0) }
        }
    }

    @objc private func tableDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0 && row < items.count else { return }
        let item = items[row]
        if item.isDir {
            pushDirectory(item.path)
        } else {
            // Same fix: savedTableSelection was captured before the first click cleared multi-select.
            let useSelection = savedTableSelection.contains(row) && savedTableSelection.count > 1
                ? savedTableSelection
                : tableView.selectedRowIndexes
            let paths = useSelection
                .compactMap { items[safe: $0] }
                .filter { !$0.isDir }
                .map { $0.path }
            (paths.isEmpty ? [item.path] : paths).forEach { client.downloadFile(path: $0) }
        }
    }

    // MARK: - Helpers

    private func currentDirectoryPath() -> String {
        if case .directory(let p) = mode { return p }
        return "/sdcard/AndroidConnect"
    }

    private func selectedPaths() -> [String] {
        if isGridView {
            return collectionView.selectionIndexPaths
                .sorted()
                .compactMap { items[safe: $0.item] }
                .filter { !$0.isDir }
                .map { $0.path }
        } else {
            return tableView.selectedRowIndexes
                .compactMap { items[safe: $0] }
                .filter { !$0.isDir }
                .map { $0.path }
        }
    }

    private func reloadAll() {
        collectionView.reloadData()
        tableView.reloadData()
    }

    private func formatSize(_ b: Int64) -> String {
        let mb = Double(b) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(b)/1024) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb/1024)
    }

    private func formatDate(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg","jpeg","png","gif","heic","webp": return "🖼️ "
        case "mp4","mov","mkv","avi":               return "🎬 "
        case "mp3","m4a","flac","wav":              return "🎵 "
        case "pdf":                                 return "📄 "
        case "zip","rar","7z":                      return "🗜️ "
        case "apk":                                 return "📦 "
        default:                                    return "📄 "
        }
    }
}

// MARK: - SocketClientDelegate

extension FileBrowserViewController: SocketClientDelegate {

    func clientConnected(to device: AndroidDevice) {
        pathLabel.stringValue = "Connected — \(device.name)"
        transferBtn.isEnabled = true
        client.listDirectory("/sdcard")
        client.requestRecentFiles(limit: 5)
        client.requestFileCounts()
    }

    func clientDisconnected() {
        items = []
        reloadAll()
        stopRefreshSpinner()
        pathLabel.stringValue   = "Disconnected"
        statusLabel.stringValue = "Waiting for device…"
        storageLabel.isHidden   = true
        storageLabel.stringValue = ""
        transferBtn.isEnabled   = false
    }

    func storageInfoReceived(_ info: StorageInfo) {
        updateStorage(info)
    }

    func dirListReceived(path: String, items: [FileItem]) {
        self.items = items
        // Normalise the display title for synthetic paths (type:images → Images)
        let label = path.hasPrefix("type:") ? path.dropFirst(5).capitalized
                  : path.hasPrefix("source:") ? path.dropFirst(7).capitalized
                  : (path.components(separatedBy: "/").last ?? path)
        pathLabel.stringValue = String(label)
        reloadAll()

        // Stop spinner and confirm refresh with a brief "Refreshed ✓" flash
        stopRefreshSpinner()
        let count = items.count
        statusLabel.stringValue = "Refreshed ✓  · \(count) item\(count == 1 ? "" : "s")"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.isRefreshing else { return }
            self.statusLabel.stringValue = "\(count) item\(count == 1 ? "" : "s")"
        }
    }

    func transferProgress(sent: Int64, total: Int64, isUpload: Bool) {
        let pct = total > 0 ? Double(sent) / Double(total) : 0
        progressBar.isHidden    = false
        progressBar.doubleValue = pct
        let dir = isUpload ? "Uploading" : "Downloading"
        statusLabel.stringValue = "\(dir)  \(Int(pct * 100))%"
    }

    func transferComplete(isUpload: Bool, url: URL?) {
        progressBar.isHidden    = true
        progressBar.doubleValue = 0
        if isUpload {
            statusLabel.stringValue = "Upload complete ✓"
            isRefreshing = false
            refresh()
        } else if let url {
            statusLabel.stringValue = "Downloaded: \(url.lastPathComponent) ✓"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func clientError(_ message: String) {
        progressBar.isHidden    = true
        statusLabel.stringValue = "Error: \(message)"
    }

    func recentFilesReceived(_ files: [RecentFile]) {
        // Propagated to parent controller for menu bar update
    }

    func fileCountsReceived(_ counts: FileTypeCounts) {
        // Forwarded to SidebarViewController via MainWindowController
    }
}

// MARK: - NSCollectionViewDataSource

extension FileBrowserViewController: NSCollectionViewDataSource {
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let cell = cv.makeItem(withIdentifier: thumbItemID, for: ip) as! FileThumbnailItem
        cell.configure(items[ip.item], client: client)
        return cell
    }
}

// MARK: - NSCollectionViewDelegate

extension FileBrowserViewController: NSCollectionViewDelegate {
    /// Called BEFORE the selection changes — save it so double-click can use the pre-click selection.
    func collectionView(_ cv: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        savedCollectionSelection = cv.selectionIndexPaths
        return indexPaths
    }
    func collectionView(_ cv: NSCollectionView, didSelectItemsAt paths: Set<IndexPath>) { }

    /// Disabling drag from the collection view removes the ~300 ms drag-disambiguation delay
    /// that NSCollectionView inserts on mouseDown when allowsMultipleSelection is true.
    /// We don't drag items out of this view, so there's no cost to returning false.
    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        return false
    }
}

// MARK: - NSTableViewDataSource

extension FileBrowserViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
}

// MARK: - NSTableViewDelegate

extension FileBrowserViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let id   = tableColumn?.identifier.rawValue ?? ""
        let cell = NSTextField()
        cell.isEditable = false; cell.isBordered = false; cell.backgroundColor = .clear
        cell.font = .systemFont(ofSize: 13)
        switch id {
        case "name":
            cell.stringValue = (item.isDir ? "📁 " : fileIcon(item.name)) + item.name
            cell.textColor   = item.isDir ? .linkColor : .labelColor
        case "size":
            cell.stringValue = item.isDir ? "—" : formatSize(item.size)
            cell.textColor   = .secondaryLabelColor; cell.alignment = .right
        case "modified":
            cell.stringValue = item.modified > 0 ? formatDate(item.modified) : ""
            cell.textColor   = .secondaryLabelColor
        default: break
        }
        return cell
    }

    /// Called BEFORE table selection changes — save it so double-click sees the pre-click selection.
    func selectionShouldChange(in tableView: NSTableView) -> Bool {
        savedTableSelection = tableView.selectedRowIndexes
        return true
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
