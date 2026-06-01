import AppKit
import UserNotifications

// MARK: - Drag overlay (intercepts file drops onto the status bar button)

final class DragOverlayView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onDragEntered: (() -> Void)?
    var onDragExited:  (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with e: NSEvent)      { superview?.mouseDown(with: e) }
    override func mouseUp(with e: NSEvent)        { superview?.mouseUp(with: e) }
    override func rightMouseDown(with e: NSEvent) { superview?.rightMouseDown(with: e) }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        layer?.backgroundColor = OPTheme.accentTint.cgColor
        onDragEntered?()
        return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) {
        layer?.backgroundColor = nil
        onDragExited?()
    }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        layer?.backgroundColor = nil
        let urls = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    override func concludeDragOperation(_ s: NSDraggingInfo?) {
        layer?.backgroundColor = nil
        onDragExited?()
    }
}

// MARK: - MenuBarController

final class MenuBarController: NSObject {

    // MARK: - Core objects

    private var statusItem: NSStatusItem!
    private let popover    = NSPopover()
    private let popoverVC  = MenuBarPopoverViewController()
    private var popoverGlobalMonitor: Any?
    private var popoverLocalMonitor: Any?

    private let discovery  = DeviceDiscovery()
    private let client     = SocketClient()
    private let events     = EventClient()

    private var windowController: MainWindowController?
    private var connectedDevice: AndroidDevice?

    // MARK: - State

    private var batteryLevel    = -1
    private var batteryCharging = false
    private var reconnecting = false  // set by reconnect() to suppress clientDisconnected timer

    // Clipboard sync
    private var pasteboardPoller: Timer?
    private var lastPasteboardCount = -1
    private var lastSentClipboard   = ""   // prevents re-sending what we just received from Android

    // Global drag monitors — detect file drags anywhere near the menu bar
    private var globalDragMonitor:    Any?
    private var globalMouseUpMonitor: Any?
    private var globalMouseDownMonitor: Any?

    // Drag pasteboard change-count at the last mouseDown.
    // We only open the drop zone if the count is higher than this — meaning files were
    // actively written to the pasteboard during THIS gesture, not left over from a previous drag.
    private var dragPasteboardBaseCount = -1

    // MARK: - Notification helper

    private let notifDelegate = NotificationDelegate()

    // MARK: - Init

    override init() {
        super.init()
        buildStatusItem()
        buildPopover()
        setupNotifications()
        discovery.delegate = self
        client.delegate    = self
        events.delegate    = self
        discovery.start()
        setupGlobalDragMonitor()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        if let img = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                             accessibilityDescription: "Android Connect") {
            img.isTemplate = true
            button.image   = img
        } else {
            button.title = "⊕"
        }

        // Click → toggle popover
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: .leftMouseUp)

        // Drag overlay — passes clicks through, intercepts file drops
        DispatchQueue.main.async { [weak self, weak button] in
            guard let self, let button else { return }
            let overlay = DragOverlayView(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]

            overlay.onDragEntered = { [weak self, weak button] in
                guard let self, let button else { return }
                // Open the popover so user sees the drop zone
                self.popoverVC.setDropActive(true)
                if !self.popover.isShown {
                    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
            overlay.onDragExited = { [weak self] in
                self?.popoverVC.setDropActive(false)
            }
            overlay.onDrop = { [weak self] urls in
                self?.popoverVC.setDropActive(false)
                self?.sendFiles(urls)
            }
            button.addSubview(overlay)
        }
    }

    // MARK: - Popover

    private func buildPopover() {
        popover.contentViewController = popoverVC
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        popoverVC.onOpenBrowser  = { [weak self] in self?.openBrowser(); self?.popover.performClose(nil) }
        popoverVC.onDownloadFile = { [weak self] path in self?.client.downloadFile(path: path) }
        popoverVC.onDrop         = { [weak self] urls in self?.sendFiles(urls) }
        popoverVC.onReconnect    = { [weak self] in self?.reconnect() }
        popoverVC.popover        = popover

        // viewDidLoad is called lazily when the popover first opens
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.close()
        } else {
            // show() first — it synchronously triggers viewDidLoad, so all views exist
            // before refreshPopover() calls update() on them.
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            
            // Force popover window to become key to ensure responder chain and transience behavior work perfectly on Sequoia/Sonoma/Tahoe
            popover.contentViewController?.view.window?.makeKey()
            
            refreshPopover()

            // Sonoma/Tahoe NSPopover click-outside transience bugfix
            popoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                DispatchQueue.main.async { self?.popover.close() }
            }
            
            popoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self else { return event }
                if self.popover.isShown {
                    if let popoverWindow = self.popover.contentViewController?.view.window,
                       event.window != popoverWindow {
                        // If it's a click in our status item button, let togglePopover handle it naturally on mouseUp (don't close here)
                        if let button = self.statusItem.button, event.window == button.window {
                            return event
                        }
                        self.popover.close()
                    }
                }
                return event
            }
        }
    }

    private func refreshPopover() {
        // Show "Model · IP" once device name arrives, otherwise just IP
        let displayName: String? = connectedDevice.map { d in
            d.name.isEmpty || d.name == "Android"
                ? d.host
                : "\(d.name) · \(d.host)"
        }
        popoverVC.update(
            deviceName:  displayName,
            battery:     batteryLevel,
            charging:    batteryCharging,
            recentFiles: client.recentFiles
        )
    }

    // MARK: - Full window

    private func openBrowser() {
        if windowController == nil {
            windowController = MainWindowController(client: client)
        }
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - File send

    private func sendFiles(_ urls: [URL]) {
        guard client.isConnected else { return }
        for url in urls { client.uploadFile(url: url, toDir: "/sdcard/AndroidConnect") }
    }

    // MARK: - Clipboard sync

    private func startClipboardSync() {
        lastPasteboardCount = NSPasteboard.general.changeCount
        pasteboardPoller = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    private func stopClipboardSync() {
        pasteboardPoller?.invalidate()
        pasteboardPoller = nil
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastPasteboardCount else { return }
        lastPasteboardCount = count
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        guard text != lastSentClipboard else { return }
        lastSentClipboard = text
        NSLog("ClipSync [Mac→Android] sending: \(text.prefix(80))")
        NSLog("ClipSync [Mac→Android] EventClient connected: \(events.isConnected)")
        events.sendClipboard(text)
    }

    // MARK: - Reconnect

    /// Drops the current connection (if any) and restarts mDNS discovery from scratch.
    /// Same as relaunching the app — use when the Android service was restarted.
    private func reconnect() {
        reconnecting = true
        client.disconnect()   // queues clientDisconnected() on main — flag suppresses its timer
        events.disconnect()
        connectedDevice = nil
        batteryLevel    = -1
        if popover.isShown { refreshPopover() }
        discovery.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.discovery.start()
        }
    }

    // MARK: - Global drag monitor (shows drop zone when dragging files near menu bar)

    private func setupGlobalDragMonitor() {
        // Snapshot the drag pasteboard state at every click so we can tell if
        // new URLs were written during THIS gesture (real file drag) vs left over
        // from a previous drag (e.g. 3-finger window move triggering stale pasteboard).
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.dragPasteboardBaseCount = NSPasteboard(name: .drag).changeCount
        }

        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            guard let self else { return }
            // Only trigger when dragging near the top of the screen (menu bar band ~80px)
            let mouseY  = NSEvent.mouseLocation.y
            let screenH = NSScreen.main?.frame.height ?? 800
            guard mouseY > screenH - 80 else { return }
            // Confirm there are actually file URLs in the drag pasteboard AND that they
            // were written during this gesture (changeCount advanced past our mouseDown snapshot).
            let pb = NSPasteboard(name: .drag)
            guard pb.types?.contains(.fileURL) == true,
                  pb.changeCount != dragPasteboardBaseCount else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.popoverVC.setDropActive(true)
                if !self.popover.isShown, let button = self.statusItem.button {
                    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                }
            }
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async { self?.popoverVC.setDropActive(false) }
        }
    }

    // MARK: - macOS notifications

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notifDelegate

        let saveAction = UNNotificationAction(identifier: "SAVE_FILE",
                                              title: "Save to Mac", options: [])
        let fileCat       = UNNotificationCategory(identifier: "NEW_FILE",
                                                   actions: [saveAction],
                                                   intentIdentifiers: [], options: [])
        let phoneCat      = UNNotificationCategory(identifier: "PHONE_NOTIF",
                                                   actions: [],
                                                   intentIdentifiers: [], options: [])
        center.setNotificationCategories([fileCat, phoneCat])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        notifDelegate.onSaveFile = { [weak self] path in
            self?.client.downloadFile(path: path)
        }
    }

    private func postFileNotification(_ file: RecentFile) {
        let c = UNMutableNotificationContent()
        c.title    = "New file on phone"
        c.body     = "\(file.name)  ·  \(formatSize(file.size))"
        c.sound    = .default
        c.categoryIdentifier = "NEW_FILE"
        c.userInfo = ["path": file.path]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: file.path, content: c, trigger: nil))
    }

    private func postPhoneNotification(_ n: PhoneNotification) {
        let c = UNMutableNotificationContent()
        c.title    = "[\(n.appLabel)]  \(n.title)"
        c.body     = n.text
        c.sound    = .default
        c.categoryIdentifier = "PHONE_NOTIF"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: n.key, content: c, trigger: nil))
    }

    private func formatSize(_ b: Int64) -> String {
        let mb = Double(b) / 1_048_576
        if mb < 1 { return String(format: "%.0f KB", Double(b)/1024) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb/1024)
    }
}

// MARK: - DeviceDiscoveryDelegate

extension MenuBarController: DeviceDiscoveryDelegate {
    func discoveryFound(_ device: AndroidDevice) {
        if !client.isConnected { client.connect(to: device) }
    }
    func discoveryLost(_ name: String) {
        if connectedDevice?.name == name {
            connectedDevice = nil; batteryLevel = -1
        }
    }
    func discoveryError(_ message: String) { }
}

// MARK: - SocketClientDelegate

extension MenuBarController: SocketClientDelegate {

    func clientConnected(to device: AndroidDevice) {
        connectedDevice = device
        events.connect(host: device.host)
        client.requestDeviceInfo()   // first in queue — name shows up immediately after connect
        client.requestStorageInfo()
        client.requestRecentFiles(limit: 5)
        client.requestFileCounts()
        startClipboardSync()
    }

    func clientDisconnected() {
        connectedDevice = nil
        batteryLevel    = -1
        stopClipboardSync()
        events.disconnect()
        if popover.isShown { refreshPopover() }
        if reconnecting {
            reconnecting = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.discovery.stop(); self?.discovery.start()
        }
    }

    func storageInfoReceived(_ info: StorageInfo) {
        windowController?.updateSidebarStorage(info)
    }

    func dirListReceived(path: String, items: [FileItem]) {
        windowController?.fileBrowser.dirListReceived(path: path, items: items)
    }

    func transferProgress(sent: Int64, total: Int64, isUpload: Bool) {
        windowController?.fileBrowser.transferProgress(sent: sent, total: total, isUpload: isUpload)
        let pct = total > 0 ? Double(sent) / Double(total) : 0
        let dir = isUpload ? "Uploading" : "Downloading"
        popoverVC.updateTransfer(progress: pct, status: "\(dir) \(Int(pct * 100))%")
    }

    func transferComplete(isUpload: Bool, url: URL?) {
        windowController?.fileBrowser.transferComplete(isUpload: isUpload, url: url)
        if !isUpload, let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        popoverVC.updateTransfer(progress: nil, status: nil)
    }

    func clientError(_ message: String) {
        windowController?.fileBrowser.clientError(message)
        popoverVC.updateTransfer(progress: nil, status: nil)
        // File deleted on phone? Refresh the recent list to drop the stale entry
        if message.lowercased().contains("not found") {
            client.requestRecentFiles(limit: 5)
        }
    }

    func recentFilesReceived(_ files: [RecentFile]) {
        // Refresh popover thumbnail row if it's open
        if popover.isShown { refreshPopover() }
    }

    func fileCountsReceived(_ counts: FileTypeCounts) {
        windowController?.updateSidebarCounts(counts)
    }
}

// MARK: - EventClientDelegate

extension MenuBarController: EventClientDelegate {

    func eventClientDisconnected() {
        // Android closed the event socket — it means the service stopped or connection dropped.
        // Trigger the normal disconnect flow so the Mac reconnects automatically.
        guard connectedDevice != nil else { return }
        client.disconnect()
    }

    func batteryUpdated(level: Int, charging: Bool) {
        batteryLevel    = level
        batteryCharging = charging
        if popover.isShown { refreshPopover() }
    }

    func fileCreatedOnPhone(_ file: RecentFile) {
        postFileNotification(file)
        // Request fresh recent list so popover stays current
        client.requestRecentFiles(limit: 5)
    }

    func notificationReceived(_ notification: PhoneNotification) {
        postPhoneNotification(notification)
    }

    func clipboardReceived(text: String) {
        lastSentClipboard   = text  // don't echo this back to Android
        lastPasteboardCount = -1    // force poller to re-read changeCount after we write
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastPasteboardCount = NSPasteboard.general.changeCount  // sync so poller skips it
    }

    func deviceNameReceived(name: String) {
        guard let device = connectedDevice else { return }
        // Replace generic "Android" name with the real device name
        connectedDevice = AndroidDevice(name: name, host: device.host, port: device.port)
        // Only refresh if popover is open — viewDidLoad hasn't run until first show,
        // so calling update() before that crashes on uninitialised views.
        // If popover is closed, refreshPopover() will be called when user opens it.
        if popover.isShown { refreshPopover() }
    }
}

// MARK: - UNUserNotificationCenterDelegate

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onSaveFile: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if response.actionIdentifier == "SAVE_FILE",
           let path = response.notification.request.content.userInfo["path"] as? String,
           !path.isEmpty {
            onSaveFile?(path)
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - NSPopoverDelegate

extension MenuBarController: NSPopoverDelegate {
    func popoverWillClose(_ notification: Notification) {
        if let monitor = popoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverGlobalMonitor = nil
        }
        if let monitor = popoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            popoverLocalMonitor = nil
        }
    }
}
