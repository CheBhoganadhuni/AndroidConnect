import Foundation
import Darwin

// MARK: - Delegate

protocol EventClientDelegate: AnyObject {
    func batteryUpdated(level: Int, charging: Bool)
    func fileCreatedOnPhone(_ file: RecentFile)
    func notificationReceived(_ notification: PhoneNotification)
    func eventClientDisconnected()
}

extension EventClientDelegate {
    func eventClientDisconnected() { }
}

// MARK: - EventClient

/// Connects to port 58001 and reads push events that Android sends unprompted.
/// Runs on a dedicated background queue — all delegate callbacks dispatched to main.
final class EventClient {

    weak var delegate: EventClientDelegate?

    private var fd: Int32 = -1
    private let fdLock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.androidconnect.events", qos: .utility)

    var isConnected: Bool {
        fdLock.lock(); defer { fdLock.unlock() }; return fd >= 0
    }

    // MARK: - Lifecycle

    func connect(host: String) {
        ioQueue.async {
            let sock = MessageProtocol.connectSocket(host: host, port: MessageProtocol.eventPort)
            guard sock >= 0 else { return }
            self.fdLock.lock(); self.fd = sock; self.fdLock.unlock()
            self.readLoop(fd: sock)
        }
    }

    func disconnect() {
        fdLock.lock()
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        fdLock.unlock()
    }

    // MARK: - Private

    private func readLoop(fd: Int32) {
        while true {
            guard let msg = try? MessageProtocol.readMessage(fd: fd) else { break }
            dispatch(msg)
        }
        fdLock.lock(); self.fd = -1; fdLock.unlock()
        // Android closed the event socket — notify so the app can trigger reconnect.
        main { self.delegate?.eventClientDisconnected() }
    }

    private func dispatch(_ msg: [String: Any]) {
        switch msg["type"] as? String {

        case "BATTERY":
            let level    = (msg["level"]    as? NSNumber)?.intValue ?? -1
            let charging = msg["charging"]  as? Bool ?? false
            main { self.delegate?.batteryUpdated(level: level, charging: charging) }

        case "FILE_CREATED":
            guard let name = msg["name"] as? String, let path = msg["path"] as? String else { return }
            let size      = (msg["size"]     as? NSNumber)?.int64Value ?? 0
            let modified  = (msg["modified"] as? NSNumber)?.int64Value ?? 0
            let mime      = msg["mime"]      as? String ?? ""
            let source    = msg["source"]   as? String ?? ""
            let thumbData = (msg["thumb"] as? String).flatMap { Data(base64Encoded: $0) }
            let file      = RecentFile(name: name, path: path, size: size,
                                       modified: modified, mime: mime,
                                       source: source, thumbData: thumbData)
            main { self.delegate?.fileCreatedOnPhone(file) }

        case "NOTIFICATION":
            let appLabel  = msg["appLabel"]  as? String ?? msg["app"] as? String ?? ""
            let title     = msg["title"]     as? String ?? ""
            let text      = msg["text"]      as? String ?? ""
            let key       = msg["key"]       as? String ?? ""
            let postTime  = (msg["postTime"] as? NSNumber)?.int64Value ?? 0
            let notif     = PhoneNotification(appLabel: appLabel, title: title,
                                              text: text, key: key, postTime: postTime)
            main { self.delegate?.notificationReceived(notif) }

        default: break
        }
    }

    private func main(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
