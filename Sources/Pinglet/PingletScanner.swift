import Foundation
import AppKit
import Network

struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let ip: String
}

final class PingletScanner: ObservableObject {
    @Published var devices: [Device] = []
    @Published var isRefreshing = false
    @Published var isScanning = false
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var isEnabled = true
    @Published var lastSeenByIP: [String: Date] = [:]

    private let maxHostsToScan = 512
    private let pingConcurrency = 32
    private let refreshInterval: TimeInterval = 60
    private let scanInterval: TimeInterval = 300
    private var autoTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "nettopbar.path.monitor")
    private var lastPathIsSatisfied = false
    private var lastWifiAvailable = false

    init() {
        startAutoRefresh()
        startPathMonitoring()
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
                self.isRefreshing = false
                self.lastUpdated = Date()
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

            if let scanError = self.sweepLocalSubnet() {
                await MainActor.run {
                    self.errorMessage = scanError
                }
            }

            let output = self.runCommand("/usr/sbin/arp", ["-a"])
            let devices = self.parseArp(output)

            await MainActor.run {
                self.devices = devices
                self.updateLastSeen(devices)
                self.isScanning = false
                self.lastUpdated = Date()
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
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

    func openTerminal(command: String) {
        let script = "tell application \"Terminal\" to do script \"\(escapeAppleScript(command))\""
        _ = runCommand("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Network Scanning

    private func sweepLocalSubnet() -> String? {
        guard let interface = primaryInterface() else {
            return "Unable to detect an active network interface."
        }

        let ip = runCommand("/usr/sbin/ipconfig", ["getifaddr", interface]).trimmed
        guard !ip.isEmpty else {
            return "No IPv4 address found on \(interface)."
        }

        let mask = runCommand("/usr/sbin/ipconfig", ["getoption", interface, "subnet_mask"]).trimmed
        let subnetMask = mask.isEmpty ? "255.255.255.0" : mask

        let hosts = subnetHosts(ip: ip, mask: subnetMask)

        if hosts.isEmpty {
            return "Unable to compute hosts for \(ip)/\(subnetMask)."
        }

        if hosts.count > maxHostsToScan {
            return "Network has \(hosts.count) hosts; skipping sweep to avoid a long scan."
        }

        let semaphore = DispatchSemaphore(value: pingConcurrency)
        let group = DispatchGroup()

        for host in hosts {
            semaphore.wait()
            group.enter()

            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer {
                    semaphore.signal()
                    group.leave()
                }

                _ = self?.runCommand("/sbin/ping", ["-c", "1", "-t", "1", host])
            }
        }

        group.wait()
        return nil
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
        var devicesByIP: [String: String] = [:]

        let pattern = "^(.+?) \\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\)"
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

            var name = String(text[nameRange]).trimmed
            let ip = String(text[ipRange])

            if name == "?" || name.isEmpty {
                continue
            }

            if devicesByIP[ip] == nil {
                devicesByIP[ip] = name
            }
        }

        let devices = devicesByIP.map { ip, name in
            Device(id: ip, name: name, ip: ip)
        }

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

    // MARK: - Utilities

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
