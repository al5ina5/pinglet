import SwiftUI
import AppKit
import Foundation

struct ContentView: View {
    @ObservedObject var scanner: PingletScanner
    @AppStorage("sshUser") private var sshUser: String = ""
    @AppStorage("scannerEnabled") private var scannerEnabled: Bool = true
    @AppStorage("leftClickAction") private var leftClickActionRaw: String = LeftClickAction.openTerminal.rawValue
    @AppStorage("privacyMode") private var privacyMode: Bool = false
    @AppStorage("showHiddenDevices") private var showHiddenDevices: Bool = false
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = false
    @AppStorage("hiddenDeviceIPs") private var hiddenDeviceIPsRaw: String = ""
    @AppStorage("favoriteDeviceIPs") private var favoriteDeviceIPsRaw: String = ""
    @AppStorage("deviceLabels") private var deviceLabelsRaw: String = "{}"
    @State private var hoveredDeviceID: String?
    @State private var actionSheet: DeviceActionSheet?
    @State private var pendingAction: PendingAction?
    @State private var searchText: String = ""
    @State private var labelSheet: DeviceLabelSheet?
    @State private var labelDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let errorMessage = scanner.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            deviceList

            footer
        }
        .padding(12)
        .frame(minWidth: 280)
        .task {
            scanner.refresh()
        }
        .onAppear {
            scannerEnabled = scanner.isEnabled
            scanner.setEnabled(scannerEnabled)
            scanner.setNotificationsEnabled(notificationsEnabled)
        }
        .onChange(of: scannerEnabled) { newValue in
            scanner.setEnabled(newValue)
        }
        .onChange(of: notificationsEnabled) { newValue in
            scanner.setNotificationsEnabled(newValue)
        }
        .sheet(item: $actionSheet) { sheet in
            SSHActionSheetView(
                device: sheet.device,
                mode: sheet.mode,
                sshUser: $sshUser,
                onSubmit: { user, command in
                    sshUser = user
                    if let pendingAction {
                        handlePendingAction(pendingAction)
                        self.pendingAction = nil
                        actionSheet = nil
                        return
                    }

                    switch sheet.mode {
                    case .setUserAndConnect:
                        openSSH(device: sheet.device, command: command)
                    case .runCommand:
                        openSSH(device: sheet.device, command: command)
                    case .setUserOnly:
                        break
                    }
                    actionSheet = nil
                },
                onCancel: {
                    actionSheet = nil
                }
            )
        }
        .sheet(item: $labelSheet) { sheet in
            DeviceLabelSheetView(
                device: sheet.device,
                label: $labelDraft,
                onSubmit: { label in
                    setLabel(label, for: sheet.device)
                    labelSheet = nil
                },
                onCancel: {
                    labelSheet = nil
                }
            )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Network Devices")
                    .font(.headline)

                if scannerEnabled {
                    if let lastUpdated = scanner.lastUpdated {
                        Text("Updated \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Disabled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: $scannerEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var deviceList: some View {
        Group {
            if scanner.devices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scanner.isRefreshing || scanner.isScanning ? "Looking for devices..." : "No devices found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    searchBar

                    if visibleDevices.isEmpty {
                        Text("No matches")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                if !favoriteDevices.isEmpty {
                                    sectionHeader("Favorites")

                                    ForEach(favoriteDevices) { device in
                                        deviceRow(device)
                                    }

                                    Divider()
                                        .padding(.vertical, 4)
                                }

                                ForEach(nonFavoriteDevices) { device in
                                    deviceRow(device)
                                }
                            }
                        }
                        .frame(maxHeight: 520)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack {
                Text("Privacy Mode")
                Spacer()
                Toggle("", isOn: $privacyMode)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            HStack {
                Text("Show Hidden")
                Spacer()
                Toggle("", isOn: $showHiddenDevices)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            HStack {
                Text("Notifications")
                Spacer()
                Toggle("", isOn: $notificationsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

        }
    }

    private func handleOpenTerminal(_ device: Device) {
        if sshUser.trimmed.isEmpty {
            pendingAction = .openTerminal(device)
            actionSheet = DeviceActionSheet(device: device, mode: .setUserOnly)
            return
        }

        openSSH(device: device, command: nil)
    }

    private func handleRunCommand(_ device: Device) {
        actionSheet = DeviceActionSheet(device: device, mode: .runCommand)
    }

    private func handleCopySSHCommand(_ device: Device) {
        if sshUser.trimmed.isEmpty {
            pendingAction = .copySSH(device)
            actionSheet = DeviceActionSheet(device: device, mode: .setUserOnly)
            return
        }

        copySSHCommand(for: device)
    }

    private func handleLeftClick(_ device: Device) {
        switch leftClickAction {
        case .openTerminal:
            handleOpenTerminal(device)
        case .copyIP:
            copyToPasteboard(device.ip)
        case .runCommand:
            handleRunCommand(device)
        case .copySSHCommand:
            handleCopySSHCommand(device)
        }
    }

    private func handleWakeOnLan(_ device: Device) {
        scanner.wakeOnLan(device: device)
    }

    private func openSSH(device: Device, command: String?) {
        let user = sshUser.trimmed
        guard !user.isEmpty else { return }

        var sshCommand = "ssh \(user)@\(device.ip)"
        if let command, !command.trimmed.isEmpty {
            sshCommand += " \(shellQuoted(command.trimmed))"
        }

        scanner.openTerminal(command: sshCommand)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func copySSHCommand(for device: Device) {
        let user = sshUser.trimmed.isEmpty ? "user" : sshUser.trimmed
        copyToPasteboard("ssh \(user)@\(device.ip)")
    }

    private func copyMAC(_ device: Device) {
        guard let mac = device.mac else { return }
        copyToPasteboard(mac)
    }

    private func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private var leftClickAction: LeftClickAction {
        LeftClickAction(rawValue: leftClickActionRaw) ?? .openTerminal
    }

    private var searchBar: some View {
        TextField("Search", text: $searchText)
            .textFieldStyle(.roundedBorder)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func maskIP(_ ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return ip }
        return "\(parts[0]).\(parts[1]).\(parts[2]).**"
    }

    private func ipDisplay(for ip: String) -> String {
        privacyMode ? maskIP(ip) : ip
    }

    private var hiddenDeviceIPs: Set<String> {
        Set(hiddenDeviceIPsRaw.split(separator: ",").map { String($0) })
    }

    private func isHidden(_ ip: String) -> Bool {
        hiddenDeviceIPs.contains(ip)
    }

    private func toggleHidden(_ ip: String) {
        var current = hiddenDeviceIPs
        if current.contains(ip) {
            current.remove(ip)
        } else {
            current.insert(ip)
        }
        hiddenDeviceIPsRaw = current.sorted().joined(separator: ",")
    }

    private var visibleDevices: [Device] {
        var devices = filteredDevices

        if !showHiddenDevices {
            devices = devices.filter { !hiddenDeviceIPs.contains($0.ip) }
        }

        let macCounts = macUsageCounts
        devices = devices.filter { !isSuspiciousUnknown($0, macCounts: macCounts) }

        return devices
    }

    private var favoriteDeviceIPs: Set<String> {
        Set(favoriteDeviceIPsRaw.split(separator: ",").map { String($0) })
    }

    private func isFavorite(_ ip: String) -> Bool {
        favoriteDeviceIPs.contains(ip)
    }

    private func toggleFavorite(_ ip: String) {
        var current = favoriteDeviceIPs
        if current.contains(ip) {
            current.remove(ip)
        } else {
            current.insert(ip)
        }
        favoriteDeviceIPsRaw = current.sorted().joined(separator: ",")
    }

    private var filteredDevices: [Device] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return scanner.devices }
        let lower = trimmed.lowercased()
        return scanner.devices.filter { device in
            let matchesName = resolvedName(for: device).lowercased().contains(lower)
            let matchesRawName = device.name.lowercased().contains(lower)
            let matchesIP = device.ip.lowercased().contains(lower)
            let matchesMAC = device.mac?.lowercased().contains(lower) ?? false
            let matchesVendor = device.vendor?.lowercased().contains(lower) ?? false
            let matchesLabel = label(for: device)?.lowercased().contains(lower) ?? false
            let matchesBonjour = scanner.mdnsNamesByIP[device.ip]?.lowercased().contains(lower) ?? false
            return matchesName || matchesRawName || matchesIP || matchesMAC || matchesVendor || matchesLabel || matchesBonjour
        }
    }

    private var favoriteDevices: [Device] {
        visibleDevices.filter { favoriteDeviceIPs.contains($0.ip) }
    }

    private var nonFavoriteDevices: [Device] {
        visibleDevices.filter { !favoriteDeviceIPs.contains($0.ip) }
    }

    private func displayName(for device: Device) -> String {
        let base = resolvedName(for: device)
        if privacyMode {
            return maskName(base)
        }
        return base
    }

    private func infoText(for device: Device) -> String? {
        var parts: [String] = []

        if let vendor = vendorDisplay(for: device) {
            parts.append(vendor)
        }

        if !privacyMode {
            if let label = label(for: device), !label.trimmed.isEmpty {
                if let mdns = scanner.mdnsNamesByIP[device.ip], mdns != label {
                    parts.append(mdns)
                } else if device.name != "Unknown Device" {
                    parts.append(device.name)
                }
            }
        }

        if let lastSeen = scanner.lastSeenByIP[device.ip] {
            let relative = relativeFormatter.localizedString(for: lastSeen, relativeTo: Date())
            parts.append("Seen \(relative)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func vendorDisplay(for device: Device) -> String? {
        if let vendor = device.vendor {
            return vendor
        }
        guard let mac = device.mac else { return nil }
        let prefix = mac.split(separator: ":").prefix(3).joined(separator: ":")
        return "OUI \(prefix.uppercased())"
    }

    private var macUsageCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for device in scanner.devices {
            if let mac = device.mac {
                counts[mac, default: 0] += 1
            }
        }
        return counts
    }

    private func isUnknown(_ device: Device) -> Bool {
        if let label = label(for: device), !label.trimmed.isEmpty {
            return false
        }
        if let mdns = scanner.mdnsNamesByIP[device.ip], !mdns.trimmed.isEmpty {
            return false
        }
        return device.name == "Unknown Device"
    }

    private func isSuspiciousUnknown(_ device: Device, macCounts: [String: Int]) -> Bool {
        guard isUnknown(device) else { return false }

        let proxyArpThreshold = 4
        let aliveWindow: TimeInterval = 300
        let now = Date()

        let lastAlive = scanner.lastAliveByIP[device.ip]
        let aliveRecently = lastAlive.map { now.timeIntervalSince($0) < aliveWindow } ?? false

        let macCount = device.mac.flatMap { macCounts[$0] } ?? 0
        let hasUniqueMac = macCount == 1
        let looksProxyArp = macCount >= proxyArpThreshold

        if aliveRecently {
            return false
        }

        if looksProxyArp {
            return true
        }

        if hasUniqueMac {
            return false
        }

        return true
    }

    private func maskName(_ name: String) -> String {
        guard !name.isEmpty else { return "Hidden" }
        let prefix = name.prefix(2)
        return "\(prefix)••••"
    }

    private func deviceRow(_ device: Device) -> some View {
        DeviceRow(
            device: device,
            isHovered: hoveredDeviceID == device.id,
            nameDisplay: displayName(for: device),
            infoText: infoText(for: device),
            ipDisplay: ipDisplay(for: device.ip),
            showHiddenIndicator: showHiddenDevices,
            isFavorite: isFavorite(device.ip),
            onLeftClick: { handleLeftClick(device) },
            onOpenTerminal: { handleOpenTerminal(device) },
            onCopyIP: { copyToPasteboard(device.ip) },
            onRunCommand: { handleRunCommand(device) },
            onCopySSH: { handleCopySSHCommand(device) },
            onCopyMAC: { copyMAC(device) },
            onWakeOnLan: { handleWakeOnLan(device) },
            leftClickAction: leftClickAction,
            onSelectLeftClickAction: { leftClickActionRaw = $0.rawValue },
            onHide: { toggleHidden(device.ip) },
            onFavorite: { toggleFavorite(device.ip) },
            isHidden: isHidden(device.ip),
            onEditLabel: { openLabelEditor(for: device) },
            onClearLabel: { setLabel("", for: device) },
            hasLabel: (label(for: device)?.trimmed.isEmpty == false),
            hasMac: device.mac != nil
        )
        .onHover { isHovering in
            hoveredDeviceID = isHovering ? device.id : nil
        }
    }

    private func openLabelEditor(for device: Device) {
        labelDraft = label(for: device) ?? ""
        labelSheet = DeviceLabelSheet(device: device)
    }

    private func label(for device: Device) -> String? {
        let map = deviceLabels
        return map[deviceLabelKey(for: device)]
    }

    private func setLabel(_ label: String, for device: Device) {
        var map = deviceLabels
        let key = deviceLabelKey(for: device)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = trimmed
        }
        deviceLabelsRaw = encodeLabels(map)
    }

    private var deviceLabels: [String: String] {
        guard let data = deviceLabelsRaw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private func encodeLabels(_ map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func deviceLabelKey(for device: Device) -> String {
        if let mac = device.mac {
            return "mac:\(mac.lowercased())"
        }
        return "ip:\(device.ip)"
    }

    private func resolvedName(for device: Device) -> String {
        if let label = label(for: device), !label.trimmed.isEmpty {
            return label
        }
        if let mdns = scanner.mdnsNamesByIP[device.ip], !mdns.trimmed.isEmpty {
            return mdns
        }
        return device.name
    }

    private var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }

    private func handlePendingAction(_ action: PendingAction) {
        switch action {
        case .openTerminal(let device):
            openSSH(device: device, command: nil)
        case .copySSH(let device):
            copySSHCommand(for: device)
        }
    }
}

private struct DeviceRow: View {
    let device: Device
    let isHovered: Bool
    let nameDisplay: String
    let infoText: String?
    let ipDisplay: String
    let showHiddenIndicator: Bool
    let isFavorite: Bool
    let onLeftClick: () -> Void
    let onOpenTerminal: () -> Void
    let onCopyIP: () -> Void
    let onRunCommand: () -> Void
    let onCopySSH: () -> Void
    let onCopyMAC: () -> Void
    let onWakeOnLan: () -> Void
    let leftClickAction: LeftClickAction
    let onSelectLeftClickAction: (LeftClickAction) -> Void
    let onHide: () -> Void
    let onFavorite: () -> Void
    let isHidden: Bool
    let onEditLabel: () -> Void
    let onClearLabel: () -> Void
    let hasLabel: Bool
    let hasMac: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 24, height: 24)

                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(nameDisplay)
                        .lineLimit(1)

                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                }

                if let infoText {
                    Text(infoText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if isHidden && showHiddenIndicator {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(ipDisplay)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)

        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.black.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onLeftClick()
        }
        .contextMenu {
            Button("Open in Terminal") {
                onOpenTerminal()
            }

            Button("Copy IP") {
                onCopyIP()
            }

            Button("Run Command...") {
                onRunCommand()
            }

            Button("Copy SSH Command") {
                onCopySSH()
            }

            if hasMac {
                Button("Copy MAC") {
                    onCopyMAC()
                }

                Button("Wake on LAN") {
                    onWakeOnLan()
                }
            }

            Divider()

            Button(isFavorite ? "Unfavorite" : "Favorite") {
                onFavorite()
            }

            Button(hasLabel ? "Edit Label..." : "Set Label...") {
                onEditLabel()
            }

            if hasLabel {
                Button("Clear Label") {
                    onClearLabel()
                }
            }

            Button(isHidden ? "Unhide" : "Hide") {
                onHide()
            }

            Divider()

            Menu("Left Click") {
                ForEach(LeftClickAction.allCases) { action in
                    Button {
                        onSelectLeftClickAction(action)
                    } label: {
                        HStack {
                            Text(action.title)
                            Spacer()
                            if action == leftClickAction {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }
}

private enum LeftClickAction: String, CaseIterable, Identifiable {
    case openTerminal
    case copyIP
    case runCommand
    case copySSHCommand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openTerminal:
            return "Open in Terminal"
        case .copyIP:
            return "Copy IP"
        case .runCommand:
            return "Run Command..."
        case .copySSHCommand:
            return "Copy SSH Command"
        }
    }
}

private enum PendingAction {
    case openTerminal(Device)
    case copySSH(Device)
}

private struct MenuRowButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct MenuRowLoadingButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, isLoading: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

private struct DeviceActionSheet: Identifiable {
    enum Mode {
        case setUserAndConnect
        case runCommand
        case setUserOnly
    }

    let id = UUID()
    let device: Device
    let mode: Mode
}

private struct DeviceLabelSheet: Identifiable {
    let id = UUID()
    let device: Device
}

private struct DeviceLabelSheetView: View {
    let device: Device
    @Binding var label: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Device Label")
                .font(.headline)

            Text("Target: \(device.name) (\(device.ip))")
                .font(.caption)
                .foregroundColor(.secondary)

            if let mac = device.mac {
                Text("MAC: \(mac)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Label")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("e.g. Living Room TV", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }

                Button("Save") {
                    onSubmit(label)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private struct SSHActionSheetView: View {
    let device: Device
    let mode: DeviceActionSheet.Mode
    @Binding var sshUser: String
    let onSubmit: (String, String?) -> Void
    let onCancel: () -> Void

    @State private var command: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Text("Target: \(device.name) (\(device.ip))")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("SSH User")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("e.g. ubuntu", text: $sshUser)
                    .textFieldStyle(.roundedBorder)
            }

            if mode == .runCommand {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("e.g. uname -a", text: $command)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }

                Button(primaryActionTitle) {
                    let trimmedUser = sshUser.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSubmit(trimmedUser, mode == .runCommand ? trimmedCommand : nil)
                }
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            if mode == .setUserAndConnect || mode == .setUserOnly {
                command = ""
            }
        }
    }

    private var title: String {
        switch mode {
        case .setUserAndConnect:
            return "Open SSH Session"
        case .runCommand:
            return "Run SSH Command"
        case .setUserOnly:
            return "Set SSH User"
        }
    }

    private var primaryActionTitle: String {
        switch mode {
        case .setUserAndConnect:
            return "Open Terminal"
        case .runCommand:
            return "Run"
        case .setUserOnly:
            return "Save"
        }
    }

    private var canSubmit: Bool {
        let hasUser = !sshUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if mode == .runCommand {
            return hasUser && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasUser
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
