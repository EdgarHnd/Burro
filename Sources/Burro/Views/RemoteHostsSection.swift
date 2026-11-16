// Settings → Machines: this Mac's keep-awake controls (KeepAwakeView.swift) and the other machines
// you added. Native SSH host setup reuses the user's existing keys/configuration without storing
// credentials. Each machine shows a status line ("Connected · checked 12 s ago", "Unreachable since
// 14:02 · retrying in 30 s") and how much Burro has cached for it, with Clear cache per machine and
// for all. The editor sheet is shared with the Machines page.
import SwiftUI
import BurroCore

struct SettingsMachinesPane: View {
    var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPaneHeader(title: "Machines", summary: summary)
            KeepAwakeSettingsGroup(keepAwake: store.keepAwake)
            RemoteHostsSection(store: store)
        }
    }
    private var summary: String {
        let on = store.remoteHosts.filter(\.enabled).count
        let others = on == 0 ? "no other machines" : on == 1 ? "1 other machine" : "\(on) other machines"
        return "This Mac and \(others), read over SSH with your own keys."
    }
}

struct RemoteHostsSection: View {
    var store: AppStore
    @State private var editing: RemoteHost?
    @State private var usage: [UUID: Int64] = [:]
    @State private var usageVersion = 0
    var body: some View {
        SettingsGroup(title: "Other laptops and servers",
                      note: "Reads Codex and Claude Code sessions over SSH. Use a Mac or Linux machine with Python 3 and an existing SSH login from this Mac. Provider app pairings are separate.") {
            ForEach(store.remoteHosts) { host in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        SettingsSwitch(label: "Read \(host.name)", isOn: Binding(get: { store.remoteHosts.first { $0.id == host.id }?.enabled ?? false },
                            set: { enabled in var value = host; value.enabled = enabled; store.saveRemoteHost(value) }))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).font(.system(size: 13, weight: .medium))
                            Text(host.destination).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                        }
                        Spacer(minLength: 8)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(store.remoteStatusLine(for: host, now: context.date)).font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
                                .lineLimit(2).multilineTextAlignment(.trailing)
                        }
                        Button { editing = host } label: { Image(systemName: "pencil") }.help("Edit remote machine")
                            .accessibilityLabel("Edit \(host.name)")
                        Button { store.removeRemoteHost(host.id) } label: { Image(systemName: "minus.circle") }.help("Remove remote machine")
                            .accessibilityLabel("Remove \(host.name)")
                    }
                    .buttonStyle(.borderless)
                    if let error = store.connection(for: host).error, host.enabled {
                        Text(error).font(.system(size: 12)).foregroundStyle(AppAppearance.amber).textSelection(.enabled)
                    }
                    if let bytes = usage[host.id], bytes > 0 {
                        HStack(spacing: 6) {
                            Text("Cache: \(Self.size(bytes)) ·").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                            Button("Clear cache") { clear(host.id) }.buttonStyle(.link).font(.system(size: 12))
                                .help("Removes what Burro copied from \(host.name): last-seen chats, transcript copies, images and videos")
                        }
                    }
                }
                SettingsRule()
            }
            if usage.values.filter({ $0 > 0 }).count > 1 {
                HStack(spacing: 6) {
                    Text("All machines: \(Self.size(usage.values.reduce(0, +))) ·").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    Button("Clear all caches") { clear(nil) }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            HStack { Button("Add remote machine…") { editing = RemoteHost(name: "", destination: "") }; Spacer() }
        }
        .sheet(item: $editing) { host in RemoteHostEditor(host: host) { store.saveRemoteHost($0) } }
        .task(id: "\(usageVersion)-\(store.remoteHosts.map(\.id))") { usage = await store.remoteCacheUsage() }
    }
    private func clear(_ id: UUID?) {
        Task { await store.clearRemoteCache(id); usageVersion += 1 }
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
struct RemoteHostEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RemoteHost
    @State private var portText: String
    var save: (RemoteHost) -> Void
    init(host: RemoteHost, save: @escaping (RemoteHost) -> Void) {
        _draft = State(initialValue: host); _portText = State(initialValue: host.port.map(String.init) ?? "")
        self.save = save
    }
    private var value: RemoteHost {
        var result = draft
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.destination = result.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        result.port = portText.isEmpty ? nil : Int(portText)
        return result
    }
    private var error: String? {
        if !portText.isEmpty && Int(portText) == nil { return "Enter a valid SSH port, or leave it blank." }
        return value.validationError
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Remote machine").font(AppAppearance.pageTitle)
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Other laptop"))
                TextField("SSH address", text: $draft.destination, prompt: Text("user@laptop.local or an SSH alias"))
                TextField("Port", text: $portText, prompt: Text("Use SSH configuration"))
            }
            Text("First confirm that SSH connects in Terminal. Burro uses your existing keys and verified host identity, then reads session metadata. No helper installation or provider login is needed; Python 3 must be available on the remote machine.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !draft.destination.isEmpty, let error { Text(error).font(.caption).foregroundStyle(AppAppearance.amber) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & connect") { save(value); dismiss() }.keyboardShortcut(.defaultAction).disabled(error != nil)
            }
        }.padding(24).frame(width: 480).modifier(AppTheme())
    }
}
