import Foundation
import AppKit
import Network
import UserNotifications
import Darwin

struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let ip: String
    let mac: String?
    let vendor: String?
}

final class PingletScanner: ObservableObject {
    @Published var devices: [Device] = []
    @Published var isRefreshing = false
    @Published var isScanning = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var isEnabled = true
    @Published var lastSeenByIP: [String: Date] = [:]
    @Published var mdnsNamesByIP: [String: String] = [:]
    @Published var lastAliveByIP: [String: Date] = [:]

    private let maxHostsToScan = 512
    private let pingConcurrency = 32
    private let refreshInterval: TimeInterval = 60
    private let scanInterval: TimeInterval = 300
    private var autoTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "nettopbar.path.monitor")
    private var lastPathIsSatisfied = false
    private var lastWifiAvailable = false
    private let vendorLookup = VendorLookup()
    private let bonjourBrowser = BonjourBrowser()
    private var knownIPs: Set<String> = []
    private var missingSince: [String: Date] = [:]
    private var hasBaseline = false
    private var notificationsEnabled = false
    private let leaveGrace: TimeInterval = 180
    private let unknownPingLimit = 512
    private let unknownPingConcurrency = 24
    private let unknownConfirmCooldown: TimeInterval = 30
    private var lastUnknownConfirmAt: Date?

    init() {
        startAutoRefresh()
        startPathMonitoring()
        startBonjourBrowsing()
    }

    func refresh() {
        guard isEnabled else { return }
        guard !isRefreshing else { return }

        isRefreshing = true
        errorMessage = nil

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let output = self.runCommand("/usr/sbin/arp", ["-a"])
            let devices = self.parseArp(output)

            await MainActor.run {
                self.devices = devices
                self.updateLastSeen(devices)
                self.handleDeviceChanges(devices)
                self.isRefreshing = false
                self.lastUpdated = Date()
                self.scheduleUnknownConfirmation(devices)
            }
        }
    }

    func scan() {
        guard isEnabled else { return }
        guard !isScanning else { return }

        isScanning = true
        errorMessage = nil

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            let sweepResult = self.sweepLocalSubnet()
            if let scanError = sweepResult.error {
                await MainActor.run {
                    self.errorMessage = scanError
                }
            }

            let output = self.runCommand("/usr/sbin/arp", ["-a"])
            let devices = self.parseArp(output)

            await MainActor.run {
                self.updateLastAlive(sweepResult.aliveIPs)
                self.devices = devices
                self.updateLastSeen(devices)
                self.handleDeviceChanges(devices)
                self.isScanning = false
                self.lastUpdated = Date()
                self.scheduleUnknownConfirmation(devices)
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        if enabled {
            hasBaseline = false
            requestNotificationAuthorization()
        }
    }

    func wakeOnLan(device: Device) {
        guard let mac = device.mac else {
            errorMessage = "No MAC address available for \(device.ip)."
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            if let error = self.sendWakePacket(mac: mac) {
                await MainActor.run {
                    self.errorMessage = error
                }
            }
        }
    }


    func startAutoRefresh() {
        guard autoTask == nil else { return }

        autoTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            var lastScan = Date.distantPast

            while !Task.isCancelled {
                await MainActor.run {
                    if self.isEnabled {
                        self.refresh()

                        let now = Date()
                        if now.timeIntervalSince(lastScan) >= self.scanInterval {
                            self.scan()
                            lastScan = now
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
            }
        }
    }

    func stopAutoRefresh() {
        autoTask?.cancel()
        autoTask = nil
    }

    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }

            let isSatisfied = path.status == .satisfied
            let wifiAvailable = path.usesInterfaceType(.wifi)

            let statusChanged = isSatisfied != self.lastPathIsSatisfied
            let wifiChanged = wifiAvailable != self.lastWifiAvailable

            self.lastPathIsSatisfied = isSatisfied
            self.lastWifiAvailable = wifiAvailable

            guard statusChanged || wifiChanged else { return }

            Task { @MainActor in
                guard self.isEnabled else { return }
                self.refresh()
                if wifiAvailable {
                    self.scan()
                }
            }
        }

        pathMonitor.start(queue: pathQueue)
    }

    private func startBonjourBrowsing() {
        bonjourBrowser.onResolve = { [weak self] ip, name in
            Task { @MainActor in
                self?.mdnsNamesByIP[ip] = name
            }
        }
        bonjourBrowser.start()
    }

    func openTerminal(command: String) {
        let script = "tell application \"Terminal\" to do script \"\(escapeAppleScript(command))\""
        _ = runCommand("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Network Scanning

    private struct SweepResult {
        let error: String?
        let aliveIPs: Set<String>
    }

    private func sweepLocalSubnet() -> SweepResult {
        guard let interface = primaryInterface() else {
            return SweepResult(error: "Unable to detect an active network interface.", aliveIPs: [])
        }

        let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", interface]).trimmed
        guard !ip.isEmpty else {
            return SweepResult(error: "No IPv4 address found on \(interface).", aliveIPs: [])
        }

        let mask = runCommand("/usr/sbin/ipconfig", ["getoption", interface, "subnet_mask"]).trimmed
        let subnetMask = mask.isEmpty ? "255.255.255.0" : mask

        let hosts = subnetHosts(ip: ip, mask: subnetMask)

        if hosts.isEmpty {
            return SweepResult(error: "Unable to compute hosts for \(ip)/\(subnetMask).", aliveIPs: [])
        }

        if hosts.count > maxHostsToScan {
            return SweepResult(error: "Network has \(hosts.count) hosts; skipping sweep to avoid a long scan.", aliveIPs: [])
        }

        let semaphore = DispatchSemaphore(value: pingConcurrency)
        let group = DispatchGroup()
        let lock = NSLock()
        var aliveIPs: Set<String> = []

        for host in hosts {
            semaphore.wait()
            group.enter()

            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    semaphore.signal()
                    group.leave()
                }

                guard let self else { return }
                let status = self.runCommandStatus("/sbin/ping", ["-c", "1", "-t", "1", host])
                if status == 0 {
                    lock.lock()
                    aliveIPs.insert(host)
                    lock.unlock()
                }
            }
        }

        group.wait()
        return SweepResult(error: nil, aliveIPs: aliveIPs)
    }

    private func primaryInterface() -> String? {
        let interfaces = ["en0", "en1", "en2"]
        for iface in interfaces {
            let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", iface]).trimmed
            if !ip.isEmpty {
                return iface
            }
        }
        return nil
    }

    // MARK: - Parsing

    private func parseArp(_ output: String) -> [Device] {
        var devicesByIP: [String: Device] = [:]

        let pattern = "^(.+?) \\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\)(?: at ((?:[0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}))?"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])

        for line in output.split(separator: "\n") {
            let text = String(line)
            if text.contains("<incomplete>") {
                continue
            }

            guard let regex else { continue }
            let range = NSRange(location: 0, length: text.utf16.count)
            guard let match = regex.firstMatch(in: text, options: [], range: range) else { continue }

            guard let nameRange = Range(match.range(at: 1), in: text),
                  let ipRange = Range(match.range(at: 2), in: text) else { continue }

            let rawName = String(text[nameRange]).trimmed
            let ip = String(text[ipRange])

            let mac = match.numberOfRanges > 3 ? Range(match.range(at: 3), in: text).map { String(text[$0]) } : nil
            let normalizedMac = mac.flatMap { normalizeMac($0) }

            let name = rawName == "?" || rawName.isEmpty ? "Unknown Device" : rawName
            let vendor = normalizedMac.flatMap { vendorLookup.vendorName(for: $0) }

            if devicesByIP[ip] == nil {
                let id = normalizedMac ?? ip
                devicesByIP[ip] = Device(id: id, name: name, ip: ip, mac: normalizedMac, vendor: vendor)
            }
        }

        let devices = devicesByIP.values

        return devices.sorted { lhs, rhs in
            (ipToUInt32(lhs.ip) ?? 0) < (ipToUInt32(rhs.ip) ?? 0)
        }
    }

    private func updateLastSeen(_ devices: [Device]) {
        let now = Date()
        for device in devices {
            lastSeenByIP[device.ip] = now
        }
    }

    private func updateLastAlive(_ aliveIPs: Set<String>) {
        guard !aliveIPs.isEmpty else { return }
        let now = Date()
        for ip in aliveIPs {
            lastAliveByIP[ip] = now
        }
    }

    private func pingIPs(_ ips: [String], concurrency: Int) -> Set<String> {
        guard !ips.isEmpty else { return [] }
        let semaphore = DispatchSemaphore(value: max(1, concurrency))
        let group = DispatchGroup()
        let lock = NSLock()
        var alive: Set<String> = []

        for ip in ips {
            semaphore.wait()
            group.enter()

            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    semaphore.signal()
                    group.leave()
                }

                guard let self else { return }
                let status = self.runCommandStatus("/sbin/ping", ["-c", "1", "-t", "1", ip])
                if status == 0 {
                    lock.lock()
                    alive.insert(ip)
                    lock.unlock()
                }
            }
        }

        group.wait()
        return alive
    }

    private func confirmIPs(_ ips: [String], concurrency: Int) -> Set<String> {
        let pingAlive = pingIPs(ips, concurrency: concurrency)
        let remaining = ips.filter { !pingAlive.contains($0) }

        guard !remaining.isEmpty else { return pingAlive }

        let semaphore = DispatchSemaphore(value: max(1, concurrency))
        let group = DispatchGroup()
        let lock = NSLock()
        var confirmed = pingAlive

        for ip in remaining {
            semaphore.wait()
            group.enter()

            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    semaphore.signal()
                    group.leave()
                }

                guard let self else { return }
                let ports: [UInt16] = [22, 80, 443]
                for port in ports {
                    if self.checkTCP(ip: ip, port: port, timeout: 1.25) {
                        lock.lock()
                        confirmed.insert(ip)
                        lock.unlock()
                        break
                    }
                }
            }
        }

        group.wait()
        return confirmed
    }

    private func checkTCP(ip: String, port: UInt16, timeout: TimeInterval) -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var finished = false
        var success = false

        func finish(_ ok: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            success = ok
            semaphore.signal()
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
                connection.cancel()
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }

        connection.start(queue: DispatchQueue.global(qos: .utility))

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            finish(false)
        }

        return success
    }

    private func handleDeviceChanges(_ devices: [Device]) {
        let currentIPs = Set(devices.map(\.ip))

        guard notificationsEnabled, isEnabled else {
            knownIPs = currentIPs
            missingSince.removeAll()
            hasBaseline = true
            return
        }

        if !hasBaseline {
            knownIPs = currentIPs
            missingSince.removeAll()
            hasBaseline = true
            return
        }

        let now = Date()

        for ip in knownIPs.subtracting(currentIPs) {
            if missingSince[ip] == nil {
                missingSince[ip] = now
            } else if let missingAt = missingSince[ip],
                      now.timeIntervalSince(missingAt) >= leaveGrace {
                notifyDeviceLeft(ip: ip)
                missingSince[ip] = nil
                knownIPs.remove(ip)
            }
        }

        for ip in currentIPs where !knownIPs.contains(ip) {
            if let device = devices.first(where: { $0.ip == ip }) {
                notifyDeviceJoined(device)
            }
            knownIPs.insert(ip)
        }

        for ip in currentIPs {
            missingSince[ip] = nil
        }
    }

    @MainActor
    private func scheduleUnknownConfirmation(_ devices: [Device]) {
        let now = Date()
        if let last = lastUnknownConfirmAt, now.timeIntervalSince(last) < unknownConfirmCooldown {
            return
        }
        lastUnknownConfirmAt = now

        let aliveSnapshot = lastAliveByIP
        let mdnsSnapshot = mdnsNamesByIP

        let candidates = devices.filter { device in
            guard device.name == "Unknown Device" else { return false }
            let mdns = mdnsSnapshot[device.ip]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard mdns.isEmpty else { return false }

            if let lastAlive = aliveSnapshot[device.ip], now.timeIntervalSince(lastAlive) < 120 {
                return false
            }

            return true
        }

        let sorted = candidates.sorted { lhs, rhs in
            (ipToUInt32(lhs.ip) ?? 0) < (ipToUInt32(rhs.ip) ?? 0)
        }
        let ips = sorted.prefix(unknownPingLimit).map(\.ip)
        guard !ips.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let alive = self.confirmIPs(ips, concurrency: self.unknownPingConcurrency)
            guard !alive.isEmpty else { return }
            await MainActor.run {
                self.updateLastAlive(alive)
            }
        }
    }

    private func notifyDeviceJoined(_ device: Device) {
        let title = "Device Joined"
        let name = resolvedName(for: device)
        sendNotification(title: title, body: "\(name) (\(device.ip))")
    }

    private func notifyDeviceLeft(ip: String) {
        let title = "Device Left"
        let name = mdnsNamesByIP[ip] ?? ip
        sendNotification(title: title, body: "\(name)")
    }

    private func resolvedName(for device: Device) -> String {
        if let mdns = mdnsNamesByIP[device.ip], !mdns.isEmpty {
            return mdns
        }
        if device.name != "Unknown Device" && !device.name.isEmpty {
            return device.name
        }
        return device.ip
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Utilities

    private func sendWakePacket(mac: String) -> String? {
        guard let macBytes = macBytes(mac) else {
            return "Invalid MAC address \(mac)."
        }

        let interface = primaryInterface()
        var broadcastIP = "255.255.255.255"

        if let interface {
            let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", interface]).trimmed
            let mask = runCommand("/usr/sbin/ipconfig", ["getoption", interface, "subnet_mask"]).trimmed
            let subnetMask = mask.isEmpty ? "255.255.255.0" : mask

            if let computed = broadcastAddress(ip: ip, mask: subnetMask) {
                broadcastIP = computed
            }
        }

        var packet = [UInt8](repeating: 0xff, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(9).bigEndian
        _ = broadcastIP.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if sock < 0 {
            return "Unable to create a UDP socket."
        }

        var on: Int32 = 1
        if setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout.size(ofValue: on))) < 0 {
            close(sock)
            return "Unable to enable UDP broadcast."
        }

        let sent: Int = packet.withUnsafeBytes { buffer in
            let bytes = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(sock, bytes, packet.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        close(sock)

        if sent < 0 {
            return "Failed to send Wake-on-LAN packet."
        }

        return nil
    }

    private func macBytes(_ mac: String) -> [UInt8]? {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        for part in parts {
            guard let byte = UInt8(part, radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    private func normalizeMac(_ mac: String) -> String? {
        let cleaned = mac.replacingOccurrences(of: "-", with: ":")
        let parts = cleaned.split(separator: ":")
        guard parts.count == 6 else { return nil }

        let normalized = parts.map { part -> String in
            let lower = part.lowercased()
            return lower.count == 1 ? "0\(lower)" : lower
        }

        return normalized.joined(separator: ":")
    }

    private func broadcastAddress(ip: String, mask: String) -> String? {
        guard let ipValue = ipToUInt32(ip), let maskValue = ipToUInt32(mask) else {
            return nil
        }

        let broadcast = (ipValue & maskValue) | ~maskValue
        return uint32ToIP(broadcast)
    }

    private func subnetHosts(ip: String, mask: String) -> [String] {
        guard let ipValue = ipToUInt32(ip), let maskValue = ipToUInt32(mask) else {
            return []
        }

        let network = ipValue & maskValue
        let broadcast = network | ~maskValue

        if broadcast <= network + 1 {
            return []
        }

        var hosts: [String] = []
        var current = network + 1
        while current < broadcast {
            let host = uint32ToIP(current)
            if host != ip {
                hosts.append(host)
            }
            current += 1
        }

        return hosts
    }

    private func ipToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }

        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt32(part), byte <= 255 else { return nil }
            value = (value << 8) | byte
        }
        return value
    }

    private func uint32ToIP(_ value: UInt32) -> String {
        let b1 = (value >> 24) & 0xff
        let b2 = (value >> 16) & 0xff
        let b3 = (value >> 8) & 0xff
        let b4 = value & 0xff
        return "\(b1).\(b2).\(b3).\(b4)"
    }

    private func runCommand(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func runCommandStatus(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return -1
        }

        process.waitUntilExit()
        return process.terminationStatus
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "\"", with: "\\\\\"")
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
