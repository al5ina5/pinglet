import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var scanner: PingletScanner
    @AppStorage("sshUser") private var sshUser: String = ""
    @AppStorage("scannerEnabled") private var scannerEnabled: Bool = true
    @AppStorage("leftClickAction") private var leftClickActionRaw: String = LeftClickAction.openTerminal.rawValue
    @AppStorage("privacyMode") private var privacyMode: Bool = false
    @AppStorage("showHiddenDevices") private var showHiddenDevices: Bool = false
    @AppStorage("hiddenDeviceIPs") private var hiddenDeviceIPsRaw: String = ""
    @AppStorage("favoriteDeviceIPs") private var favoriteDeviceIPsRaw: String = ""
    @State private var hoveredDeviceID: String?
    @State private var actionSheet: DeviceActionSheet?
    @State private var pendingAction: PendingAction?
    @State private var searchText: String = ""

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
        }
        .onChange(of: scannerEnabled) { newValue in
            scanner.setEnabled(newValue)
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
        if showHiddenDevices {
            return filteredDevices
        }
        return filteredDevices.filter { !hiddenDeviceIPs.contains($0.ip) }
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
        return scanner.devices.filter {
            $0.name.lowercased().contains(lower) || $0.ip.lowercased().contains(lower)
        }
    }

    private var favoriteDevices: [Device] {
        visibleDevices.filter { favoriteDeviceIPs.contains($0.ip) }
    }

    private var nonFavoriteDevices: [Device] {
        visibleDevices.filter { !favoriteDeviceIPs.contains($0.ip) }
    }

    private func displayName(for device: Device) -> String {
        if privacyMode {
            return maskName(device.name)
        }
        return device.name
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
            ipDisplay: ipDisplay(for: device.ip),
            showHiddenIndicator: showHiddenDevices,
            isFavorite: isFavorite(device.ip),
            onLeftClick: { handleLeftClick(device) },
            onOpenTerminal: { handleOpenTerminal(device) },
            onCopyIP: { copyToPasteboard(device.ip) },
            onRunCommand: { handleRunCommand(device) },
            onCopySSH: { handleCopySSHCommand(device) },
            leftClickAction: leftClickAction,
            onSelectLeftClickAction: { leftClickActionRaw = $0.rawValue },
            onHide: { toggleHidden(device.ip) },
            onFavorite: { toggleFavorite(device.ip) },
            isHidden: isHidden(device.ip)
        )
        .onHover { isHovering in
            hoveredDeviceID = isHovering ? device.id : nil
        }
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
    let ipDisplay: String
    let showHiddenIndicator: Bool
    let isFavorite: Bool
    let onLeftClick: () -> Void
    let onOpenTerminal: () -> Void
    let onCopyIP: () -> Void
    let onRunCommand: () -> Void
    let onCopySSH: () -> Void
    let leftClickAction: LeftClickAction
    let onSelectLeftClickAction: (LeftClickAction) -> Void
    let onHide: () -> Void
    let onFavorite: () -> Void
    let isHidden: Bool

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

            HStack(spacing: 6) {
                Text(nameDisplay)
                    .lineLimit(1)

                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.accentColor)
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

            Divider()

            Button(isFavorite ? "Unfavorite" : "Favorite") {
                onFavorite()
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
