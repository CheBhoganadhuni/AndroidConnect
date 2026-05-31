import Foundation
import Darwin

struct AndroidDevice {
    let name: String
    let host: String   // resolved IPv4 string, e.g. "192.168.43.1"
    let port: Int
}

protocol DeviceDiscoveryDelegate: AnyObject {
    func discoveryFound(_ device: AndroidDevice)
    func discoveryLost(_ name: String)
    func discoveryError(_ message: String)
}

final class DeviceDiscovery: NSObject {
    weak var delegate: DeviceDiscoveryDelegate?

    private var browser: NetServiceBrowser?
    private var resolving: [NetService] = []
    private var fallbackTimer: Timer?

    func start() {
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: MessageProtocol.serviceType, inDomain: "local.")
        browser = b

        // If mDNS finds nothing in 5s (e.g. phone is in hotspot mode and NSD only
        // advertises on wlan0, not ap0), fall back to probing the default gateway
        // directly — when the Mac is on the phone's hotspot, the gateway IS the phone.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.tryGatewayFallback()
        }
    }

    func stop() {
        browser?.stop()
        browser = nil
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    // MARK: - Gateway fallback

    private func tryGatewayFallback() {
        guard let gw = defaultGateway() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let fd = MessageProtocol.connectSocket(host: gw, port: MessageProtocol.port)
            guard fd >= 0 else { return }
            Darwin.close(fd)
            let device = AndroidDevice(name: "Android", host: gw, port: Int(MessageProtocol.port))
            DispatchQueue.main.async { self?.delegate?.discoveryFound(device) }
        }
    }

    private func defaultGateway() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // Extract IPv4 string from the resolved NetService addresses
    private func ipv4(from service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for addr in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = addr.withUnsafeBytes { raw -> Bool in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return false }
                if sa.pointee.sa_family != UInt8(AF_INET) { return false }
                return getnameinfo(sa, socklen_t(addr.count),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0,
                                   NI_NUMERICHOST) == 0
            }
            if ok {
                let ip = String(cString: hostname)
                if !ip.isEmpty { return ip }
            }
        }
        return nil
    }
}

extension DeviceDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        DispatchQueue.main.async { self.delegate?.discoveryLost(service.name) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        DispatchQueue.main.async { self.delegate?.discoveryError("Browse error \(code)") }
    }
}

extension DeviceDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        fallbackTimer?.invalidate(); fallbackTimer = nil
        guard let ip = ipv4(from: sender) else {
            // fallback to hostname if IP extraction fails
            if let host = sender.hostName {
                let device = AndroidDevice(name: sender.name, host: host, port: sender.port)
                resolving.removeAll { $0 === sender }
                DispatchQueue.main.async { self.delegate?.discoveryFound(device) }
            }
            return
        }
        let device = AndroidDevice(name: sender.name, host: ip, port: sender.port)
        resolving.removeAll { $0 === sender }
        DispatchQueue.main.async { self.delegate?.discoveryFound(device) }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}
