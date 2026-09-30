// Host-scoped session browsing and read-only remote details never route remote paths into local actions.
import SwiftUI
import AppKit
import BurroCore

struct RemoteSessionsView: View {
    @Bindable var store: AppStore
    @State private var adding: RemoteHost?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote sessions").font(.title2.weight(.semibold))
                    Text("Codex and Claude Code across your machines").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refreshRemotes() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.checkingRemotes).help("Refresh remote sessions")
                Button { adding = RemoteHost(name: "", destination: "") } label: { Image(systemName: "plus") }.help("Add remote machine")
            }.padding(Layout.inset)
            if store.remoteHosts.isEmpty {
                ContentUnavailableView {
                    Label("Connect your other laptop", systemImage: "laptopcomputer.and.arrow.down")
                } description: {
                    Text("Add an SSH address to see its Codex and Claude Code sessions here and in the notch.")
                } actions: {
                    Button("Add remote machine…") { adding = RemoteHost(name: "", destination: "") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.remoteSelection) {
                    ForEach(store.remoteHosts) { host in
                        let connection = store.connection(for: host)
                        let sessions = store.remoteSessions.filter { $0.remote?.hostID == host.id && matches($0) }
                        Section {
                            if store.checkingRemotes && connection.sampledAt == nil && host.enabled {
                                ForEach(0..<3, id: \.self) { _ in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Session activity on your laptop")
                                        Text("Provider · workspace").font(.caption)
                                    }.redacted(reason: .placeholder).accessibilityHidden(true).padding(.vertical, 3)
                                }
                                Text("Connecting to \(host.name)…").font(.caption).foregroundStyle(.secondary)
                            } else if sessions.isEmpty {
                                Text(emptyMessage(connection)).font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(sessions) { session in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: session.provider == .codex ? "terminal" : "sparkle").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.title).lineLimit(2)
                                        Text("\(session.provider.rawValue) · \(URL(fileURLWithPath: session.cwd).lastPathComponent)")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(session.remote?.stale == true ? "Last seen" : session.statusLabel)
                                        .font(.caption).foregroundStyle(session.statusColor)
                                }.padding(.vertical, 5).tag(session.id)
                            }
                            if let error = connection.error, host.enabled {
                                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                            }
                            ForEach(connection.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        } header: {
                            HStack {
                                Text(host.name)
                                Spacer()
                                Text(connection.state.rawValue).foregroundStyle(connection.state == .offline ? .orange : .secondary)
                            }
                        }
                    }
                }.listStyle(.inset)
            }
            HStack {
                Text("Remote status refreshes every 10 seconds")
                Spacer()
                SettingsLink { Text("Manage machines") }
            }.font(.caption).foregroundStyle(.secondary).padding(Layout.inset)
        }
        .sheet(item: $adding) { RemoteHostEditor(host: $0) { store.saveRemoteHost($0) } }
    }
    private func matches(_ session: AgentSession) -> Bool {
        store.search.isEmpty || [session.title, session.cwd, session.remote?.hostName ?? "", session.provider.rawValue]
            .contains { $0.localizedCaseInsensitiveContains(store.search) }
    }
    private func emptyMessage(_ snapshot: RemoteHostSnapshot) -> String {
        switch snapshot.state {
        case .disabled: "Monitoring is paused for this machine."
        case .offline: "This machine is unreachable. Retrying automatically."
        case .notChecked: "Waiting for the first connection."
        case .online: store.search.isEmpty ? "No open sessions found on this machine." : "No matching sessions."
        }
    }
}
struct RemoteSessionDetailView: View {
    var store: AppStore
    var body: some View {
        if let session = store.selectedRemote, let origin = session.remote {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label(origin.hostName, systemImage: "laptopcomputer").foregroundStyle(.secondary)
                    Text(session.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Label(session.remote?.stale == true ? "Last seen · connection unavailable" : session.statusLabel,
                          systemImage: origin.stale ? "wifi.slash" : "circle.fill")
                        .font(.callout).foregroundStyle(session.statusColor)
                    LabeledContent("Agent", value: session.provider.rawValue)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remote workspace").font(.caption).foregroundStyle(.secondary)
                        Text(session.cwd).font(.callout.monospaced()).textSelection(.enabled)
                        Button("Copy path") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.cwd, forType: .string)
                        }.buttonStyle(.borderless)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Last checked").font(.caption).foregroundStyle(.secondary)
                        Text(origin.sampledAt, style: .relative)
                        Text(session.evidence).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Cleanup checks are available for worktrees on this Mac only.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(Layout.inset).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a remote session", systemImage: "network",
                description: Text("Its machine, activity, and workspace appear here."))
        }
    }
}
