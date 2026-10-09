// Native SSH host setup reuses the user's existing keys/configuration without storing credentials.
import SwiftUI
import BurroCore

struct RemoteHostsSection: View {
    var store: AppStore
    @State private var editing: RemoteHost?
    var body: some View {
        Section("Remote laptops & servers") {
            ForEach(store.remoteHosts) { host in
                HStack {
                    Toggle(isOn: Binding(get: { store.remoteHosts.first { $0.id == host.id }?.enabled ?? false },
                        set: { enabled in var value = host; value.enabled = enabled; store.saveRemoteHost(value) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(host.name)
                            Text(host.destination).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(store.connection(for: host).state.rawValue).font(.caption).foregroundStyle(.secondary)
                    Button { editing = host } label: { Image(systemName: "pencil") }.help("Edit remote machine")
                    Button { store.removeRemoteHost(host.id) } label: { Image(systemName: "minus.circle") }.help("Remove remote machine")
                }.buttonStyle(.borderless)
                if let error = store.connection(for: host).error, host.enabled {
                    Text(error).font(.caption).foregroundStyle(AppAppearance.amber).textSelection(.enabled)
                }
            }
            Button("Add remote machine…") { editing = RemoteHost(name: "", destination: "") }
            Text("Reads Codex and Claude Code sessions over SSH. Use a Mac or Linux machine with Python 3 and an existing SSH login from this Mac. Provider app pairings are separate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { host in RemoteHostEditor(host: host) { store.saveRemoteHost($0) } }
    }
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
