import Foundation
import AppKit
import Darwin

// MARK: - Delegate

protocol SocketClientDelegate: AnyObject {
    func clientConnected(to device: AndroidDevice)
    func clientDisconnected()
    func storageInfoReceived(_ info: StorageInfo)
    func dirListReceived(path: String, items: [FileItem])
    func transferProgress(sent: Int64, total: Int64, isUpload: Bool)
    func transferComplete(isUpload: Bool, url: URL?)
    func clientError(_ message: String)
    func recentFilesReceived(_ files: [RecentFile])
    func fileCountsReceived(_ counts: FileTypeCounts)
    func deviceNameReceived(name: String)
}

// Default no-op implementations so existing conformers don't need to change
extension SocketClientDelegate {
    func recentFilesReceived(_ files: [RecentFile]) { }
    func fileCountsReceived(_ counts: FileTypeCounts) { }
    func deviceNameReceived(name: String) { }
}

// MARK: - SocketClient

final class SocketClient {
    weak var delegate: SocketClientDelegate?

    private var fd: Int32 = -1
    private let ioQueue = DispatchQueue(label: "com.androidconnect.io", qos: .userInitiated)
    private let fdLock = NSLock()
    private var isTransferring = false

    // Recent files from phone (last 5 shown in menu bar)
    private(set) var recentFiles: [RecentFile] = []

    var isConnected: Bool { currentFd() >= 0 }

    // In-memory thumbnail cache — NSCache is thread-safe and evicts under memory pressure
    private let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    // Generation counter: bumped by downloadFile/uploadFile so queued thumbnails bail fast.
    private var thumbGeneration: Int = 0
    private let thumbGenLock = NSLock()

    // Download-pending flag: set before enqueuing a download so _recentFiles bails immediately
    // instead of blocking the serial ioQueue with a full TCP round-trip.
    private var downloadPending = false
    private let downloadPendingLock = NSLock()

    func cachedThumbnail(for path: String) -> NSImage? {
        thumbCache.object(forKey: path as NSString)
    }

    // MARK: - Connection

    func connect(to device: AndroidDevice) {
        ioQueue.async {
            let sock = MessageProtocol.connectSocket(host: device.host, port: Int32(device.port))
            guard sock >= 0 else {
                self.mainCallback { $0.clientError("Could not connect to \(device.host)") }
                return
            }
            self.fdLock.lock(); self.fd = sock; self.fdLock.unlock()
            self.mainCallback { $0.clientConnected(to: device) }
        }
    }

    func disconnect() {
        fdLock.lock(); if fd >= 0 { Darwin.close(fd); fd = -1 }; fdLock.unlock()
        mainCallback { $0.clientDisconnected() }
    }

    // MARK: - File operations

    func requestStorageInfo() {
        ioQueue.async { self._storageInfo() }
    }

    func listDirectory(_ path: String) {
        ioQueue.async { self._listDir(path) }
    }

    func downloadFile(path: String) {
        bumpThumbGeneration()
        downloadPendingLock.lock(); downloadPending = true; downloadPendingLock.unlock()
        ioQueue.async { self._download(path: path) }
    }

    func uploadFile(url: URL, toDir destPath: String) {
        bumpThumbGeneration()
        downloadPendingLock.lock(); downloadPending = true; downloadPendingLock.unlock()
        ioQueue.async { self._upload(url: url, toDir: destPath) }
    }

    private func bumpThumbGeneration() {
        thumbGenLock.lock(); thumbGeneration += 1; thumbGenLock.unlock()
    }

    // MARK: - Mode-based queries (type filter / source filter)

    func getFilesByType(_ type: String, offset: Int = 0, limit: Int = 200) {
        ioQueue.async { self._filesByType(type, offset: offset, limit: limit) }
    }

    func getFilesBySource(_ source: String) {
        ioQueue.async { self._filesBySource(source) }
    }

    // MARK: - Recent files + counts (for file browser sidebar)

    func requestRecentFiles(limit: Int = 20) {
        ioQueue.async { self._recentFiles(limit: limit) }
    }

    func requestFileCounts() {
        ioQueue.async { self._fileCounts() }
    }

    /// Fetches user-set device name (Bluetooth/hotspot name or model) from Android.
    func requestDeviceInfo() {
        ioQueue.async {
            let sock = self.currentFd(); guard sock >= 0 else { return }
            do {
                try MessageProtocol.writeMessage(fd: sock, ["cmd": "GET_DEVICE_INFO"])
                let msg = try MessageProtocol.readMessage(fd: sock)
                guard msg["type"] as? String == "DEVICE_INFO",
                      let model = msg["model"] as? String, !model.isEmpty else { return }
                self.mainCallback { $0.deviceNameReceived(name: model) }
            } catch { /* non-fatal — IP alone is sufficient */ }
        }
    }

    // Thumbnail request — serves from NSCache instantly if available, otherwise fetches over TCP.
    func requestThumbnail(path: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbCache.object(forKey: path as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }
        // Capture generation at enqueue time; if it changed by the time we run,
        // a download/upload was requested — bail immediately so it isn't blocked.
        thumbGenLock.lock(); let gen = thumbGeneration; thumbGenLock.unlock()
        ioQueue.async {
            self.thumbGenLock.lock()
            let current = self.thumbGeneration
            self.thumbGenLock.unlock()
            guard gen == current else { DispatchQueue.main.async { completion(nil) }; return }
            let sock = self.currentFd(); guard sock >= 0 else { DispatchQueue.main.async { completion(nil) }; return }
            do {
                try MessageProtocol.writeMessage(fd: sock, ["cmd": "GET_THUMBNAIL", "path": path])
                let msg = try MessageProtocol.readMessage(fd: sock)
                guard msg["type"] as? String == "THUMBNAIL",
                      let b64  = msg["data"] as? String,
                      let data = Data(base64Encoded: b64),
                      let img  = NSImage(data: data) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                self.thumbCache.setObject(img, forKey: path as NSString)
                DispatchQueue.main.async { completion(img) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
                self.handleError(error)
            }
        }
    }

    // MARK: - Private I/O

    private func currentFd() -> Int32 {
        fdLock.lock(); defer { fdLock.unlock() }; return fd
    }

    private func _storageInfo() {
        let sock = currentFd(); guard sock >= 0 else { return }
        do {
            try MessageProtocol.writeMessage(fd: sock, ["cmd": "STORAGE_INFO"])
            let msg = try MessageProtocol.readMessage(fd: sock)
            guard msg["type"] as? String == "STORAGE_INFO" else { return }
            let info = StorageInfo(
                total: (msg["total"] as? NSNumber)?.int64Value ?? 0,
                free:  (msg["free"]  as? NSNumber)?.int64Value ?? 0,
                used:  (msg["used"]  as? NSNumber)?.int64Value ?? 0,
                root:  msg["root"] as? String ?? "/"
            )
            mainCallback { $0.storageInfoReceived(info) }
        } catch { handleError(error) }
    }

    private func _listDir(_ path: String) {
        let sock = currentFd(); guard sock >= 0 else { return }
        do {
            try MessageProtocol.writeMessage(fd: sock, ["cmd": "LIST_DIR", "path": path])
            let msg = try MessageProtocol.readMessage(fd: sock)
            guard msg["type"] as? String == "DIR_LIST" else { return }
            let currentPath = msg["path"] as? String ?? path
            let items = (msg["items"] as? [[String: Any]] ?? []).map { d -> FileItem in
                FileItem(
                    name:     d["name"]     as? String ?? "",
                    isDir:    d["isDir"]    as? Bool   ?? false,
                    size:     (d["size"]    as? NSNumber)?.int64Value ?? 0,
                    modified: (d["modified"] as? NSNumber)?.int64Value ?? 0,
                    path:     d["path"]     as? String ?? ""
                )
            }
            mainCallback { $0.dirListReceived(path: currentPath, items: items) }
        } catch { handleError(error) }
    }

    private func _download(path: String) {
        downloadPendingLock.lock(); downloadPending = false; downloadPendingLock.unlock()
        let sock = currentFd(); guard sock >= 0 else { return }
        isTransferring = true
        defer { isTransferring = false }
        do {
            try MessageProtocol.writeMessage(fd: sock, ["cmd": "GET_FILE", "path": path])
            let msg = try MessageProtocol.readMessage(fd: sock)
            if msg["type"] as? String == "ERROR" {
                mainCallback { $0.clientError(msg["msg"] as? String ?? "Error") }
                return
            }
            guard msg["type"] as? String == "FILE_START",
                  let name = msg["name"] as? String,
                  let size = (msg["size"] as? NSNumber)?.int64Value else { return }

            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let dest = downloads.appendingPathComponent(name)
            // Direct Darwin.write to a raw fd — fastest possible, no ObjC/NSData overhead.
            let filefd = Darwin.open(dest.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard filefd >= 0 else { return }

            var received: Int64 = 0
            var lastProgressReport: Int64 = 0
            let progressStride: Int64 = 1_048_576  // report UI every 1 MB
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: MessageProtocol.bufferSize)
            defer { buf.deallocate(); Darwin.close(filefd) }

            while received < size {
                let n = Darwin.read(sock, buf, min(MessageProtocol.bufferSize, Int(size - received)))
                guard n > 0 else { throw ConnectError.disconnected }
                var off = 0
                while off < n {
                    let w = Darwin.write(filefd, buf.advanced(by: off), n - off)
                    guard w > 0 else { throw ConnectError.disconnected }
                    off += w
                }
                received += Int64(n)
                if received - lastProgressReport >= progressStride {
                    lastProgressReport = received
                    let snap = received
                    mainCallback { $0.transferProgress(sent: snap, total: size, isUpload: false) }
                }
            }

            mainCallback { $0.transferProgress(sent: size, total: size, isUpload: false) }
            mainCallback { $0.transferComplete(isUpload: false, url: dest) }
        } catch { handleError(error) }
    }

    private func _upload(url: URL, toDir destPath: String) {
        downloadPendingLock.lock(); downloadPending = false; downloadPendingLock.unlock()
        let sock = currentFd(); guard sock >= 0 else { return }
        isTransferring = true
        defer { isTransferring = false }
        do {
            guard let attrs = try? Foundation.FileManager.default.attributesOfItem(atPath: url.path),
                  let fileSize = attrs[.size] as? Int64,
                  let fileStream = InputStream(url: url) else { return }

            try MessageProtocol.writeMessage(fd: sock, [
                "cmd": "PUT_FILE",
                "name": url.lastPathComponent,
                "size": fileSize,
                "dest_path": destPath
            ])
            let ready = try MessageProtocol.readMessage(fd: sock)
            guard ready["type"] as? String == "READY" else { return }

            fileStream.open(); defer { fileStream.close() }
            var sent: Int64 = 0
            var lastProgressReport: Int64 = 0
            let progressStride: Int64 = 1_048_576  // report UI every 1 MB
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: MessageProtocol.bufferSize)
            defer { buf.deallocate() }

            while sent < fileSize {
                let n = fileStream.read(buf, maxLength: MessageProtocol.bufferSize)
                guard n > 0 else { break }
                var off = 0
                while off < n {
                    let w = Darwin.write(sock, buf.advanced(by: off), n - off)
                    guard w > 0 else { throw ConnectError.disconnected }
                    off += w
                }
                sent += Int64(n)
                if sent - lastProgressReport >= progressStride {
                    lastProgressReport = sent
                    let snap = sent
                    mainCallback { $0.transferProgress(sent: snap, total: fileSize, isUpload: true) }
                }
            }
            mainCallback { $0.transferProgress(sent: fileSize, total: fileSize, isUpload: true) }
            let done = try MessageProtocol.readMessage(fd: sock)
            guard done["type"] as? String == "PUT_DONE" else { return }
            mainCallback { $0.transferComplete(isUpload: true, url: nil) }
        } catch { handleError(error) }
    }

    private func _recentFiles(limit: Int) {
        // Bail instantly if a download/upload is already queued — don't block it with a round-trip.
        downloadPendingLock.lock(); let skip = downloadPending; downloadPendingLock.unlock()
        guard !skip else { return }
        let sock = currentFd(); guard sock >= 0 else { return }
        do {
            try MessageProtocol.writeMessage(fd: sock, ["cmd": "GET_RECENT_FILES", "limit": limit])
            let msg = try MessageProtocol.readMessage(fd: sock)
            guard msg["type"] as? String == "RECENT_FILES",
                  let arr = msg["files"] as? [[String: Any]] else { return }
            let files = arr.compactMap { d -> RecentFile? in
                guard let name = d["name"] as? String, let path = d["path"] as? String else { return nil }
                let thumbData = (d["thumb"] as? String).flatMap { Data(base64Encoded: $0) }
                return RecentFile(
                    name:      name,
                    path:      path,
                    size:      (d["size"]     as? NSNumber)?.int64Value ?? 0,
                    modified:  (d["modified"] as? NSNumber)?.int64Value ?? 0,
                    mime:      d["mime"]   as? String ?? "",
                    source:    d["source"] as? String ?? "",
                    thumbData: thumbData
                )
            }
            // Cache top 5 for menu bar
            DispatchQueue.main.async {
                self.recentFiles = Array(files.prefix(5))
            }
            mainCallback { $0.recentFilesReceived(files) }
        } catch { handleError(error) }
    }

    private func _fileCounts() {
        let sock = currentFd(); guard sock >= 0 else { return }
        do {
            try MessageProtocol.writeMessage(fd: sock, ["cmd": "GET_FILE_COUNTS"])
            let msg = try MessageProtocol.readMessage(fd: sock)
            guard msg["type"] as? String == "FILE_COUNTS" else { return }
            let counts = FileTypeCounts(
                images:    (msg["images"]    as? NSNumber)?.intValue ?? 0,
                videos:    (msg["videos"]    as? NSNumber)?.intValue ?? 0,
                audio:     (msg["audio"]     as? NSNumber)?.intValue ?? 0,
                documents: (msg["documents"] as? NSNumber)?.intValue ?? 0,
                archives:  (msg["archives"]  as? NSNumber)?.intValue ?? 0,
                apks:      (msg["apks"]      as? NSNumber)?.intValue ?? 0
            )
            mainCallback { $0.fileCountsReceived(counts) }
        } catch { handleError(error) }
    }

    private func _filesByType(_ type: String, offset: Int, limit: Int) {
        let sock = currentFd(); guard sock >= 0 else { return }
        do {
            try MessageProtocol.writeMessage(fd: sock, ["cmd": "GET_FILES_BY_TYPE",
                "type": type, "offset": offset, "limit": limit])
            let msg = try MessageProtocol.readMessage(fd: sock)
            guard msg["type"] as? String == "FILE_LIST",
                  let arr = msg["items"] as? [[String: Any]] else { return }
            let items = parseFileItems(arr)
            mainCallback { $0.dirListReceived(path: "type:\(type)", items: items) }
        } catch { handleError(error) }
    }

    private func _filesBySource(_ source: String) {
        let sock = currentFd(); guard sock >= 0 else { return }
        do {
            try MessageProtocol.writeMessage(fd: sock, ["cmd": "GET_FILES_BY_SOURCE", "source": source])
            let msg = try MessageProtocol.readMessage(fd: sock)
            guard msg["type"] as? String == "DIR_LIST",
                  let arr = msg["items"] as? [[String: Any]] else { return }
            let path = msg["path"] as? String ?? "source:\(source)"
            let items = parseFileItems(arr)
            mainCallback { $0.dirListReceived(path: path, items: items) }
        } catch { handleError(error) }
    }

    private func parseFileItems(_ arr: [[String: Any]]) -> [FileItem] {
        arr.map { d in
            FileItem(
                name:     d["name"]     as? String ?? "",
                isDir:    d["isDir"]    as? Bool   ?? false,
                size:     (d["size"]     as? NSNumber)?.int64Value ?? 0,
                modified: (d["modified"] as? NSNumber)?.int64Value ?? 0,
                path:     d["path"]     as? String ?? ""
            )
        }
    }

    private func handleError(_ error: Error) {
        if case ConnectError.disconnected = error {
            fdLock.lock(); fd = -1; fdLock.unlock()
            mainCallback { $0.clientDisconnected() }
        } else {
            mainCallback { $0.clientError(error.localizedDescription) }
        }
    }

    private func mainCallback(_ block: @escaping (SocketClientDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let d = self?.delegate else { return }
            block(d)
        }
    }
}
