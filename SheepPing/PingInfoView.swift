import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Column geometry (shared between header and rows)

private enum Col {
    static let dot:     CGFloat = 26
    static let host:    CGFloat = 185
    static let ip:      CGFloat = 138
    static let status:  CGFloat = 76   // capsule badge needs a bit more room
    static let latency: CGFloat = 88
    static let success: CGFloat = 70
    static let failed:  CGFloat = 62
    static let rate:    CGFloat = 64
    static let hPad:    CGFloat = 14
    static let rowH:    CGFloat = 32
}

// MARK: - PingInfoView

struct PingInfoView: View {
    @StateObject private var vm = PingViewModel()
    @State private var showAddSheet  = false
    @State private var showSettings  = false
    @State private var anchorID: UUID? = nil   // shift-click range anchor

    /// True while a modal sheet owns the keyboard.
    ///
    /// The toolbar's key equivalents are registered as menu shortcuts, and macOS
    /// dispatches those ahead of the responder chain — ⌘A, ⌘C and Delete would
    /// otherwise be taken from the text fields in the sheets instead of editing
    /// text. A disabled shortcut is skipped, so gating on this hands the keys
    /// back for as long as a sheet is up.
    private var sheetIsUp: Bool { showAddSheet || showSettings }

    var body: some View {
        VSplitView {
            tableSection
                .frame(minHeight: 220)
            logSection
                .frame(minHeight: 160)
        }
        .frame(minWidth: 940, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .toolbar { buildToolbar() }
        .background(keyboardBackstops)
        .sheet(isPresented: $showAddSheet) { AddHostSheet { vm.addHost($0) } }
        .sheet(isPresented: $showSettings) { SettingsSheet(vm: vm) }
        .preferredColorScheme(vm.theme.colorScheme)
    }

    // MARK: Table

    private var tableSection: some View {
        VStack(spacing: 0) {
            HostTableHeader()
            Divider()
            if vm.hosts.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(vm.hosts.enumerated()), id: \.element.id) { idx, host in
                            HostTableRow(
                                host: host,
                                isSelected: vm.selectedHostIDs.contains(host.id),
                                isEven: idx % 2 == 0
                            )
                            .onTapGesture { selectHost(host) }
                            .contextMenu {
                                Button {
                                    copyPingRows([host])
                                } label: {
                                    Label("Copy Ping Row", systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image("SheepOutline")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 64)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No Hosts")
                .font(.title2.bold())
                .foregroundStyle(.primary)
            Text("Tap  +  in the toolbar to add an IP address or hostname.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: Log

    private var logSection: some View {
        VStack(spacing: 0) {
            let sel = vm.selectedHosts
            if sel.isEmpty {
                logPlaceholder
            } else if sel.count == 1 {
                HostLogSection(host: sel[0])
            } else {
                MultiSelectionPanel(hosts: sel, allHosts: vm.hosts)
            }
        }
    }

    private var logPlaceholder: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft").foregroundStyle(.tertiary)
                Text("Select a host to view its log").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, Col.hPad)
            .padding(.vertical, 8)
            .background(.bar)
            Divider()
            Color(NSColor.controlBackgroundColor)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func buildToolbar() -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {

            Button { showAddSheet = true } label: {
                Label("Add Host", systemImage: "plus")
            }
            .help("Add a new host to monitor")

            Button { removeSelected() } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(vm.selectedHostIDs.isEmpty || sheetIsUp)
            .help("Remove selected host(s) (⌦ or ⌫)")
            .keyboardShortcut(.deleteForward, modifiers: [])

            Divider()

            Button { vm.stopAll() } label: {
                Label("Stop All", systemImage: "stop.fill")
            }
            .disabled(!vm.anyActive)
            .help("Stop all active pings")

            Button { vm.resumeAll() } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .disabled(!vm.anyInactive)
            .help("Resume stopped hosts")

            Button { vm.restartAll() } label: {
                Label("Restart All", systemImage: "arrow.clockwise")
            }
            .disabled(vm.hosts.isEmpty)
            .help("Clear stats and restart all hosts")

            Divider()

            // Live status chip
            if !vm.hosts.isEmpty {
                statusChip
            }

            Button { showSettings = true } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .help("Ping interval and other settings")
        }
    }

    /// Shortcut-only actions. A Button carries one key equivalent, and the
    /// Remove button spends its on ⌦ (fn+⌫), so a zero-sized twin claims the
    /// bare ⌫. Select All (⌘A) and Copy (⌘C) lost their toolbar buttons on
    /// request (2026-08-26) and now live here on their shortcuts alone.
    /// Same guards as the visible controls they mirror.
    private var keyboardBackstops: some View {
        Group {
            Button("Remove selected hosts") { removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(vm.selectedHostIDs.isEmpty || sheetIsUp)
            Button("Select all hosts") { selectAllHosts() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(vm.hosts.isEmpty || sheetIsUp)
            Button("Copy selected ping rows") { copyPingRows(vm.selectedHosts) }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(vm.selectedHostIDs.isEmpty || sheetIsUp)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Circle().fill(vm.anyActive ? Color.green : Color.gray).frame(width: 7, height: 7)
            Text(vm.anyActive ? "\(vm.sessions.count) active" : "Stopped")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: Actions

    private func selectHost(_ host: PingHost) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift), let anchor = anchorID,
           let ai = vm.hosts.firstIndex(where: { $0.id == anchor }),
           let ti = vm.hosts.firstIndex(where: { $0.id == host.id }) {
            // Range select: keep anchor, select everything between anchor and tapped row
            let lo = min(ai, ti), hi = max(ai, ti)
            vm.selectedHostIDs = Set(vm.hosts[lo...hi].map(\.id))
        } else if mods.contains(.command) {
            // Toggle individual item
            if vm.selectedHostIDs.contains(host.id) {
                vm.selectedHostIDs.remove(host.id)
            } else {
                vm.selectedHostIDs.insert(host.id)
                anchorID = host.id
            }
        } else {
            // Plain click — single select
            vm.selectedHostIDs = [host.id]
            anchorID = host.id
        }
    }

    private func removeSelected() {
        for host in vm.selectedHosts { vm.removeHost(host) }
    }

    private func selectAllHosts() {
        vm.selectedHostIDs = Set(vm.hosts.map(\.id))
        anchorID = vm.hosts.first?.id
    }

    private func copyPingRows(_ hosts: [PingHost]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pingCSV(hosts), forType: .string)
    }

    private func pingCSV(_ hosts: [PingHost]) -> String {
        var lines = ["Host,Resolved IP,Status,Latency (ms),Success,Failed,Rate (%),Active"]
        for host in hosts {
            let resolvedIP = host.resolvedIP.isEmpty ? "" : host.resolvedIP
            let latency = host.latency.map { String(format: "%.1f", $0) } ?? ""
            let rate = host.successCount + host.failCount == 0
                ? ""
                : String(format: "%.0f", host.successRate)
            lines.append([
                csv(host.address),
                csv(resolvedIP),
                csv(host.status.label),
                csv(latency),
                csv("\(host.successCount)"),
                csv("\(host.failCount)"),
                csv(rate),
                csv(host.isActive ? "Yes" : "No")
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    private func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

// MARK: - HostTableHeader

private struct HostTableHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Col.dot)
            hdr("Host",        Col.host,    .leading)
            hdr("Resolved IP", Col.ip,      .leading)
            hdr("Status",      Col.status,  .leading)
            hdr("Latency",     Col.latency, .trailing)
            hdr("Success",     Col.success, .trailing)
            hdr("Failed",      Col.failed,  .trailing)
            hdr("Rate",        Col.rate,    .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Col.hPad)
        .frame(height: 26)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func hdr(_ label: String, _ width: CGFloat, _ align: Alignment) -> some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: align)
    }
}

// MARK: - HostTableRow
// @ObservedObject is the key: every @Published change on PingHost redraws only this row.

struct HostTableRow: View {
    @ObservedObject var host: PingHost
    let isSelected: Bool
    let isEven: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Status dot
            StatusDot(status: host.status)
                .frame(width: Col.dot)

            // Host address
            Text(host.address)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .frame(width: Col.host, alignment: .leading)

            // Resolved IP
            Text(host.resolvedIP.isEmpty ? "—" : host.resolvedIP)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Col.ip, alignment: .leading)

            // Status badge
            statusBadge
                .frame(width: Col.status, alignment: .leading)

            // Latency chip
            latencyCell
                .font(.system(size: 12, design: .monospaced))
                .frame(width: Col.latency, alignment: .trailing)

            // Success
            Text("\(host.successCount)")
                .font(.system(size: 13, design: .monospaced).monospacedDigit())
                .foregroundStyle(.green)
                .frame(width: Col.success, alignment: .trailing)

            // Failed
            Text("\(host.failCount)")
                .font(.system(size: 13, design: .monospaced).monospacedDigit())
                .foregroundStyle(host.failCount > 0 ? Color.red : Color.secondary)
                .frame(width: Col.failed, alignment: .trailing)

            // Rate
            Text(host.successRate == 0 && host.successCount + host.failCount == 0
                 ? "—"
                 : String(format: "%.0f%%", host.successRate))
                .font(.system(size: 13, design: .monospaced).monospacedDigit())
                .foregroundStyle(rateColor(host.successRate))
                .frame(width: Col.rate, alignment: .trailing)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Col.hPad)
        .frame(height: Col.rowH)
        .background(background)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }

    // MARK: Sub-views

    private var statusBadge: some View {
        Text(host.status.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(host.status.dotColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(host.status.dotColor.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private var latencyCell: some View {
        if let ms = host.latency {
            Text(String(format: ms < 1000 ? "%.1f ms" : "%.0f ms", ms))
                .foregroundStyle(latencyColor(ms))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered  { return Color.primary.opacity(0.04) }
        return isEven
            ? Color(NSColor.controlBackgroundColor)
            : Color(NSColor.alternatingContentBackgroundColors.count > 1
                    ? NSColor.alternatingContentBackgroundColors[1]
                    : NSColor.controlBackgroundColor)
    }

    // MARK: Helpers

    private func latencyColor(_ ms: Double) -> Color {
        ms < 30 ? .green : ms < 120 ? Color(NSColor.systemYellow) : .red
    }

    private func rateColor(_ r: Double) -> Color {
        r >= 95 ? .green : r >= 75 ? Color(NSColor.systemOrange) : .red
    }
}

// MARK: - StatusDot

struct StatusDot: View {
    let status: PingStatus
    @State private var pulse = false

    var body: some View {
        ZStack {
            if status == .running {
                Circle()
                    .fill(status.dotColor.opacity(0.28))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulse ? 1.0 : 0.5)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                               value: pulse)
                    .onAppear { pulse = true }
            }
            Circle()
                .fill(status.dotColor)
                .frame(width: 9, height: 9)
                .shadow(color: status == .idle ? .clear : status.dotColor.opacity(0.5), radius: 3)
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - HostLogSection  (@ObservedObject keeps log list real-time)

struct HostLogSection: View {
    @ObservedObject var host: PingHost
    @State private var copiedFeedback  = false
    @State private var savedFeedback   = false
    @State private var clearedFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                StatusDot(status: host.status).scaleEffect(0.85)
                Text(host.address).fontWeight(.semibold)
                Text("·").foregroundStyle(.tertiary)
                Text(host.resolvedIP.isEmpty ? "resolving…" : host.resolvedIP)
                    .foregroundStyle(.secondary)
                    .font(.system(.callout, design: .monospaced))
                Spacer()
                Text("\(host.log.count) entries")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if !host.log.isEmpty {
                    Divider().frame(height: 14)
                    LogActionButton(
                        label: copiedFeedback ? "Copied!" : "Copy",
                        icon:  copiedFeedback ? "checkmark" : "doc.on.doc",
                        tint:  copiedFeedback ? .green : .secondary,
                        active: copiedFeedback
                    ) {
                        copyLog(host: host)
                        flash($copiedFeedback, duration: 1.5)
                    }
                    .help("Copy log to clipboard")
                    LogActionButton(
                        label: savedFeedback ? "Saved!" : "Save…",
                        icon:  savedFeedback ? "checkmark" : "square.and.arrow.down",
                        tint:  savedFeedback ? .green : .secondary,
                        active: savedFeedback
                    ) {
                        saveLog(host: host, onSaved: { flash($savedFeedback, duration: 1.5) })
                    }
                    .help("Save log as CSV")
                    Divider().frame(height: 14)
                    LogActionButton(
                        label: clearedFeedback ? "Cleared!" : "Clear",
                        icon:  nil,
                        tint:  clearedFeedback ? .orange : .secondary,
                        active: clearedFeedback
                    ) {
                        host.log.removeAll()
                        flash($clearedFeedback, duration: 1.2)
                    }
                    .help("Clear log")
                }
            }
            .padding(.horizontal, Col.hPad)
            .padding(.vertical, 7)
            .background(.bar)

            Divider()

            // Log list
            List(host.log) { entry in
                LogRow(entry: entry)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Feedback helper

    private func flash(_ flag: Binding<Bool>, duration: Double) {
        flag.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            flag.wrappedValue = false
        }
    }

    // MARK: Log export helpers

    private func logCSV(host: PingHost) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["Timestamp,Status,Latency (ms),Message"]
        for e in host.log.reversed() {
            let ts  = fmt.string(from: e.timestamp)
            let st  = e.isSuccess ? "OK" : "Fail"
            let lat = e.latency.map { String(format: "%.1f", $0) } ?? ""
            let msg = e.message.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(ts),\(st),\(lat),\"\(msg)\"")
        }
        return lines.joined(separator: "\n")
    }

    private func copyLog(host: PingHost) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logCSV(host: host), forType: .string)
    }

    private func saveLog(host: PingHost, onSaved: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let safe = host.address.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "ping-\(safe).csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // `try?` here used to swallow the failure and still flash "Saved!",
            // so a read-only destination or a full disk looked like a success.
            do {
                try logCSV(host: host).write(to: url, atomically: true, encoding: .utf8)
                onSaved?()
            } catch {
                presentSaveFailure(error, url: url)
            }
        }
    }
}

// MARK: - LogRow

struct LogRow: View {
    let entry: LogEntry

    static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            // Success / fail indicator
            RoundedRectangle(cornerRadius: 2)
                .fill(entry.isSuccess ? Color.green : Color.red)
                .frame(width: 3, height: 14)
                .padding(.trailing, 8)

            // Time
            Text(Self.fmt.string(from: entry.timestamp))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            // Latency
            Group {
                if let ms = entry.latency {
                    Text(String(format: "%6.1f ms", ms))
                        .foregroundStyle(ms < 30 ? .green : ms < 120 ? Color(NSColor.systemYellow) : .red)
                } else {
                    Text("  timeout")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 76, alignment: .trailing)

            // Message
            Text(entry.message)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 10)

            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.vertical, 2)
    }
}

// MARK: - LogActionButton

struct LogActionButton: View {
    let label:  String
    let icon:   String?
    let tint:   Color
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon {
                    Label(label, systemImage: icon)
                } else {
                    Text(label)
                }
            }
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? tint.opacity(0.15) : Color.clear)
            )
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - MultiSelectionPanel

struct MultiSelectionPanel: View {
    let hosts: [PingHost]
    let allHosts: [PingHost]
    @State private var savedSelFeedback = false
    @State private var savedAllFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                Text("\(hosts.count) hosts selected").fontWeight(.semibold)
                Spacer()
                LogActionButton(
                    label: savedSelFeedback ? "Saved!" : "Save Selected…",
                    icon:  savedSelFeedback ? "checkmark" : "square.and.arrow.down",
                    tint:  savedSelFeedback ? .green : .secondary,
                    active: savedSelFeedback
                ) { saveCSV(hosts, onSaved: { flash($savedSelFeedback) }) }
                .help("Save selected hosts' logs as CSV")

                LogActionButton(
                    label: savedAllFeedback ? "Saved!" : "Save All…",
                    icon:  savedAllFeedback ? "checkmark" : "square.and.arrow.down.fill",
                    tint:  savedAllFeedback ? .green : .secondary,
                    active: savedAllFeedback
                ) { saveCSV(allHosts, onSaved: { flash($savedAllFeedback) }) }
                .help("Save all hosts' logs as CSV")
            }
            .padding(.horizontal, Col.hPad)
            .padding(.vertical, 7)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(hosts) { host in
                        HStack(spacing: 8) {
                            StatusDot(status: host.status).scaleEffect(0.75)
                            Text(host.address)
                                .font(.system(.callout, design: .monospaced))
                            Spacer()
                            Text("\(host.log.count) entries")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Col.hPad)
                        .padding(.vertical, 5)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func combinedCSV(_ hostsToExport: [PingHost]) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["Host,Timestamp,Status,Latency (ms),Message"]
        for h in hostsToExport {
            for e in h.log.reversed() {
                let ts  = fmt.string(from: e.timestamp)
                let st  = e.isSuccess ? "OK" : "Fail"
                let lat = e.latency.map { String(format: "%.1f", $0) } ?? ""
                let msg = e.message.replacingOccurrences(of: "\"", with: "\"\"")
                lines.append("\(h.address),\(ts),\(st),\(lat),\"\(msg)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func saveCSV(_ hostsToSave: [PingHost], onSaved: @escaping () -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let safe = hostsToSave.count == 1
            ? hostsToSave[0].address.replacingOccurrences(of: "/", with: "-")
            : nil
        panel.nameFieldStringValue = safe.map { "ping-\($0).csv" } ?? "ping-export.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try combinedCSV(hostsToSave).write(to: url, atomically: true, encoding: .utf8)
                onSaved()
            } catch {
                presentSaveFailure(error, url: url)
            }
        }
    }

    private func flash(_ flag: Binding<Bool>, duration: Double = 1.5) {
        flag.wrappedValue = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            flag.wrappedValue = false
        }
    }
}

// MARK: - AddHostSheet

struct AddHostSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    let onAdd: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Add Host", systemImage: "plus.circle.fill")
                .font(.title2.bold())

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                if text.isEmpty {
                    Text("8.8.8.8\ngoogle.com\n2606:4700:4700::1111")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

            Text("One host per line — IP addresses and hostnames are both supported. DNS is resolved automatically. Press ⌘↩ to add.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { submit() }
                    // ⌘↩, not bare Return as the default action: the editor is
                    // multi-line, and plain Return has to keep inserting lines.
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .forEach { onAdd($0) }
        dismiss()
    }
}

// MARK: - SettingsSheet

struct SettingsSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var vm: PingViewModel
    // Local slider value: dragging must NOT hit applyInterval() per tick —
    // that stops and restarts every ping session (new process per host) and
    // writes UserDefaults on each movement. Commit once when the drag ends.
    @State private var intervalDraft: Double = 0
    // Same reasoning as intervalDraft: committing per tick would restart every session.
    @State private var timeoutDraft: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Settings", systemImage: "slider.horizontal.3")
                .font(.title2.bold())

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ping Interval").fontWeight(.medium)
                            Text("How often each host is pinged")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f s", intervalDraft))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    Slider(value: $intervalDraft, in: 0.5...30, step: 0.5) { editing in
                        if !editing { vm.applyInterval(intervalDraft) }
                    }
                    .onAppear { intervalDraft = vm.interval }
                    .onChange(of: vm.interval) { _, newVal in
                        // Keep the draft in sync if the interval changes elsewhere
                        intervalDraft = newVal
                    }
                    HStack {
                        Text("0.5 s (fast)").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text("30 s (slow)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text("Changes apply immediately to all active hosts and are saved as the default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
            } label: {
                Label("Ping Interval", systemImage: "timer")
                    .font(.callout.bold())
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reply Timeout").fontWeight(.medium)
                            Text("How long to wait for a reply before marking a ping failed")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f s", timeoutDraft))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    Slider(value: $timeoutDraft,
                           in: PingViewModel.minPingTimeout...PingViewModel.maxPingTimeout,
                           step: 0.5) { editing in
                        if !editing { vm.applyTimeout(timeoutDraft) }
                    }
                    .onAppear { timeoutDraft = vm.pingTimeout }
                    .onChange(of: vm.pingTimeout) { _, newVal in timeoutDraft = newVal }
                    HStack {
                        Text(String(format: "%.1f s", PingViewModel.minPingTimeout))
                            .font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text(String(format: "%.0f s", PingViewModel.maxPingTimeout))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if timeoutDraft < 1 {
                        Label("Below 1 s, hosts on slow or distant links will report false timeouts.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color(NSColor.systemOrange))
                    } else {
                        Text("Independent of the ping interval, so a fast interval no longer marks slow hosts as failed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            } label: {
                Label("Reply Timeout", systemImage: "clock.badge.exclamationmark")
                    .font(.callout.bold())
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Appearance").fontWeight(.medium)
                            Text("Override the system color scheme")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { vm.theme },
                            set: { vm.setTheme($0) }
                        )) {
                            ForEach(AppTheme.allCases, id: \.self) { t in
                                Text(t.label).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                }
                .padding(6)
            } label: {
                Label("Appearance", systemImage: "paintbrush")
                    .font(.callout.bold())
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

// MARK: - Save failure reporting

@MainActor
private func presentSaveFailure(_ error: Error, url: URL) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Couldn't save \(url.lastPathComponent)"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
