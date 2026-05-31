import AppKit

// MARK: - Sidebar delegate

protocol SidebarDelegate: AnyObject {
    func sidebar(_ vc: SidebarViewController, didSelect mode: BrowserMode)
}

// MARK: - Sidebar row model

private enum SidebarRow {
    case sectionHeader(String)
    case navItem(icon: String, iconTint: NSColor, label: String, count: Int?, mode: BrowserMode,
                 dotColor: NSColor?)
    case storageBar
}

// MARK: - SidebarViewController

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: SidebarDelegate?

    private let tableView  = NSTableView()
    private let scrollView = NSScrollView()
    private let storageBar = NSProgressIndicator()
    private let storageLabel = NSTextField(labelWithString: "")

    private var rows: [SidebarRow] = []
    private var counts = FileTypeCounts(images: 0, videos: 0, audio: 0, documents: 0, archives: 0, apks: 0)
    private var selectedRow = 1   // defaults to "All Files"

    // MARK: - Lifecycle

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = OPTheme.sidebarBg.cgColor
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildTable()
        buildStorageBar()
        rebuildRows()
    }

    // MARK: - Public

    func updateCounts(_ c: FileTypeCounts) {
        counts = c
        rebuildRows()
    }

    func updateStorage(_ info: StorageInfo) {
        storageLabel.stringValue = "\(info.usedGB) / \(info.totalGB)"
        storageBar.doubleValue   = info.usedFraction
    }

    // MARK: - Build

    private func buildTable() {
        let col = NSTableColumn(identifier: .init("main"))
        col.isEditable = false
        tableView.addTableColumn(col)
        tableView.headerView        = nil
        tableView.delegate          = self
        tableView.dataSource        = self
        tableView.rowHeight         = 32
        tableView.backgroundColor   = .clear
        tableView.intercellSpacing  = NSSize(width: 0, height: 0)
        tableView.allowsEmptySelection = false
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.selectionHighlightStyle = .none  // we draw selection ourselves

        scrollView.documentView     = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.borderType       = .noBorder
        scrollView.backgroundColor  = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
    }

    private func buildStorageBar() {
        storageBar.style           = .bar
        storageBar.isIndeterminate = false
        storageBar.minValue        = 0; storageBar.maxValue = 1
        storageBar.translatesAutoresizingMaskIntoConstraints = false

        storageLabel.font          = .systemFont(ofSize: 10)
        storageLabel.textColor     = OPTheme.dim
        storageLabel.alignment     = .center
        storageLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(storageBar)
        view.addSubview(storageLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: storageBar.topAnchor, constant: -8),

            storageBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            storageBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            storageBar.bottomAnchor.constraint(equalTo: storageLabel.topAnchor, constant: -4),

            storageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            storageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            storageLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
        ])
    }

    private func rebuildRows() {
        rows = [
            .sectionHeader("FILES"),
            .navItem(icon: "folder.fill",        iconTint: OPTheme.accent, label: "All Files",  count: nil, mode: .directory(path: "/sdcard"), dotColor: nil),
            .navItem(icon: "photo.on.rectangle", iconTint: NSColor(red: 0.95, green: 0.48, blue: 0.0, alpha: 1), label: "Images",    count: counts.images,    mode: .byType("images"), dotColor: nil),
            .navItem(icon: "film",               iconTint: NSColor(red: 0.8,  green: 0.1,  blue: 0.1, alpha: 1), label: "Videos",    count: counts.videos,    mode: .byType("videos"), dotColor: nil),
            .navItem(icon: "music.note",         iconTint: NSColor(red: 0.55, green: 0.1,  blue: 0.9, alpha: 1), label: "Audio",     count: counts.audio,     mode: .byType("audio"),  dotColor: nil),
            .navItem(icon: "doc.text",           iconTint: OPTheme.accent, label: "Documents", count: counts.documents, mode: .byType("documents"), dotColor: nil),
            .navItem(icon: "archivebox",         iconTint: OPTheme.body,   label: "Archives",  count: counts.archives,  mode: .byType("archives"),  dotColor: nil),
            .navItem(icon: "shippingbox",        iconTint: OPTheme.body,   label: "APKs",      count: counts.apks,      mode: .byType("apks"),      dotColor: nil),

            .sectionHeader("SOURCES"),
            .navItem(icon: "arrow.down.circle.fill",    iconTint: OPTheme.dotDownloads, label: "Downloads", count: nil, mode: .bySource("downloads"), dotColor: OPTheme.dotDownloads),
            .navItem(icon: "camera.fill",               iconTint: OPTheme.dotDCIM,      label: "DCIM",      count: nil, mode: .bySource("dcim"),      dotColor: OPTheme.dotDCIM),
            .navItem(icon: "message.fill",              iconTint: OPTheme.dotWhatsApp,  label: "WhatsApp",  count: nil, mode: .bySource("whatsapp"),  dotColor: OPTheme.dotWhatsApp),
            .navItem(icon: "wave.3.right",              iconTint: OPTheme.dotBluetooth, label: "Bluetooth", count: nil, mode: .bySource("bluetooth"), dotColor: OPTheme.dotBluetooth),
            .navItem(icon: "clock.arrow.circlepath",    iconTint: OPTheme.dotRecent,    label: "Recent",    count: nil, mode: .recent,                dotColor: OPTheme.dotRecent),
        ]
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
    }

    // MARK: - Action

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 && row < rows.count else { return }
        if case .navItem(_, _, _, _, let mode, _) = rows[row] {
            selectedRow = row
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            delegate?.sidebar(self, didSelect: mode)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = NSTableRowView()
        rv.isEmphasized = false
        return rv
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let isSelected = (row == selectedRow)

        switch rows[row] {
        case .sectionHeader(let title):
            let cell = NSView()
            let lbl  = makeLabel(title, font: .systemFont(ofSize: 10, weight: .bold), color: OPTheme.dim)
            lbl.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(lbl)
            NSLayoutConstraint.activate([
                lbl.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
                lbl.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case .navItem(let icon, let iconTint, let label, let count, _, let dotColor):
            // Selection highlight row
            let cell = NSView()
            cell.wantsLayer = true
            cell.layer?.cornerRadius    = 7
            cell.layer?.backgroundColor = isSelected ? OPTheme.accentTint.cgColor : NSColor.clear.cgColor

            // Icon (or colored dot for sources)
            let iconView: NSView
            if let dot = dotColor, dotColor != nil {
                let d = OPTheme.dot(color: dot, size: 9)
                d.translatesAutoresizingMaskIntoConstraints = false
                iconView = d
                _ = icon; _ = iconTint  // suppress warnings
            } else {
                let img = NSImageView()
                img.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                img.contentTintColor = isSelected ? OPTheme.accent : iconTint
                img.translatesAutoresizingMaskIntoConstraints = false
                iconView = img
            }

            let lbl      = makeLabel(label, font: .systemFont(ofSize: 13), color: isSelected ? OPTheme.accent : OPTheme.title)
            let countLbl = makeLabel(count.map { "\($0)" } ?? "",
                                     font: .systemFont(ofSize: 11), color: OPTheme.dim)
            countLbl.alignment = .right

            for v: NSView in [iconView, lbl, countLbl] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }

            let iconW: CGFloat = dotColor != nil ? 9 : 16
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
                iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: iconW),
                iconView.heightAnchor.constraint(equalToConstant: iconW),

                lbl.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
                lbl.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                lbl.trailingAnchor.constraint(lessThanOrEqualTo: countLbl.leadingAnchor, constant: -4),

                countLbl.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                countLbl.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                countLbl.widthAnchor.constraint(equalToConstant: 44),
            ])
            return cell

        case .storageBar:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .sectionHeader = rows[row] { return 26 }
        return 34
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .navItem = rows[row] { return true }
        return false
    }

    private func makeLabel(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = font; f.textColor = color
        return f
    }
}
