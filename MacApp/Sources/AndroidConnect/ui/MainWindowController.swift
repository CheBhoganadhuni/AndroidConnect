import AppKit

final class MainWindowController: NSWindowController {

    let fileBrowser: FileBrowserViewController
    private let client: SocketClient

    init(client: SocketClient) {
        self.client      = client
        self.fileBrowser = FileBrowserViewController(client: client)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.title          = "Android Connect"
        window.minSize        = NSSize(width: 600, height: 450)
        window.setFrameAutosaveName("ACMainWindow")
        window.appearance     = NSAppearance(named: .aqua)   // always light
        if window.frame.isEmpty { window.center() }

        super.init(window: window)

        window.contentView = fileBrowser.view

        // Trigger initial state if already connected
        if client.isConnected {
            fileBrowser.applyMode(.directory(path: "/sdcard"))
            client.requestStorageInfo()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Called by MenuBarController when storage info arrives
    func updateSidebarStorage(_ info: StorageInfo) {
        fileBrowser.updateStorage(info)
    }

    // No-op — sidebar removed, file counts no longer needed
    func updateSidebarCounts(_ counts: FileTypeCounts) { }
}
