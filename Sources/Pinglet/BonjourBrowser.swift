import Foundation
import Darwin

final class BonjourBrowser: NSObject {
    private let serviceTypes = [
        "_workstation._tcp.",
        "_ssh._tcp.",
        "_http._tcp.",
        "_smb._tcp.",
        "_device-info._tcp."
    ]

    private var browsers: [NetServiceBrowser] = []
    private var services: Set<NetService> = []

    var onResolve: ((String, String) -> Void)?

    func start() {
        stop()

        for type in serviceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func stop() {
        for browser in browsers {
            browser.stop()
        }
        browsers.removeAll()
        services.removeAll()
    }
}

extension BonjourBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.insert(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.remove(service)
    }
}

extension BonjourBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses else { return }

        for address in addresses {
            if let ip = ipv4Address(from: address) {
                onResolve?(ip, sender.name)
                return
            }
        }
    }
}

private func ipv4Address(from data: Data) -> String? {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return nil }
        let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)

        guard sockaddrPointer.pointee.sa_family == sa_family_t(AF_INET) else { return nil }

        let inetAddress = baseAddress.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
        var address = inetAddress

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }

        return String(cString: buffer)
    }
}
