import Foundation
import Darwin

// MARK: - Shared constants

enum ConnectError: Error, LocalizedError {
    case disconnected
    case invalidMessage
    case connectionFailed(String)
    case fileError(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Device disconnected"
        case .invalidMessage: return "Protocol error"
        case .connectionFailed(let s): return "Connection failed: \(s)"
        case .fileError(let s): return "File error: \(s)"
        }
    }
}

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Int64
    let path: String
}

struct StorageInfo {
    let total: Int64
    let free: Int64
    let used: Int64
    let root: String

    var freeGB: String { String(format: "%.1f GB free", Double(free) / 1_073_741_824) }
    var usedGB: String { String(format: "%.1f GB used", Double(used) / 1_073_741_824) }
    var totalGB: String { String(format: "%.1f GB total", Double(total) / 1_073_741_824) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

// MARK: - Message framing (4-byte big-endian length prefix + JSON body)

// MARK: - Data models

struct RecentFile {
    let name: String
    let path: String
    let size: Int64
    let modified: Int64
    let mime: String
    let source: String
    let thumbData: Data?

    var isImage: Bool { mime.hasPrefix("image/") }
    var isVideo: Bool { mime.hasPrefix("video/") }
    var isAudio: Bool { mime.hasPrefix("audio/") }
}

struct FileTypeCounts {
    let images: Int
    let videos: Int
    let audio: Int
    let documents: Int
    let archives: Int
    let apks: Int
}

// File browser navigation mode — drives what the right panel shows
enum BrowserMode: Equatable {
    case directory(path: String)   // plain directory listing
    case recent                    // GET_RECENT_FILES
    case byType(String)            // GET_FILES_BY_TYPE  "images"|"videos"|"audio"|"documents"|"archives"|"apks"
    case bySource(String)          // LIST_DIR on a well-known folder  "downloads"|"dcim"|"whatsapp"|"bluetooth"

    var displayTitle: String {
        switch self {
        case .directory(let p): return p.components(separatedBy: "/").last ?? p
        case .recent:           return "Recent files"
        case .byType(let t):    return t.capitalized
        case .bySource(let s):  return s.capitalized
        }
    }
}

struct PhoneNotification {
    let appLabel: String
    let title: String
    let text: String
    let key: String
    let postTime: Int64
}

// MARK: - Protocol constants + framing

enum MessageProtocol {
    static let port: Int32 = 58000
    static let eventPort: Int32 = 58001   // Android → Mac push channel
    static let serviceType = "_androidconnect._tcp."
    static let bufferSize = 65536

    static func readMessage(fd: Int32) throws -> [String: Any] {
        let lenData = try readExactly(fd: fd, count: 4)
        let len = Int(lenData.withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) })
        guard len > 0, len <= 10_485_760 else { throw ConnectError.invalidMessage }
        let body = try readExactly(fd: fd, count: len)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ConnectError.invalidMessage
        }
        return obj
    }

    static func writeMessage(fd: Int32, _ dict: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: dict)
        var be = UInt32(body.count).bigEndian
        let header = Data(bytes: &be, count: 4)
        try writeAll(fd: fd, data: header)
        try writeAll(fd: fd, data: body)
    }

    static func readExactly(fd: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            let n = result.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            guard n > 0 else { throw ConnectError.disconnected }
            offset += n
        }
        return result
    }

    static func writeAll(fd: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard n > 0 else { throw ConnectError.disconnected }
            offset += n
        }
    }

    // Open a blocking TCP connection (synchronous, call on background thread)
    static func connectSocket(host: String, port: Int32) -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        defer { freeaddrinfo(res) }

        guard getaddrinfo(host, "\(port)", &hints, &res) == 0 else { return -1 }

        var ptr = res
        while let ai = ptr {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    // Disable Nagle — we're sending bulk data, latency matters
                    var one: Int32 = 1
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    // Large socket buffers for high throughput
                    var bufSize: Int32 = 1_048_576
                    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
                    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
                    return fd
                }
                Darwin.close(fd)
            }
            ptr = ai.pointee.ai_next
        }
        return -1
    }
}
