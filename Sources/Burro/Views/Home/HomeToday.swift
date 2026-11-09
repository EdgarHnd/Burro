// Today's to-dos on Home: tick, type to add, double-click to edit. Shared with Maurice through
// Convex when sync is set up; otherwise kept on this Mac until it is.
import SwiftUI
import BurroCore

struct HomeTodayCard: View {
    @Bindable var todos: TodoStore
    @State private var draft = ""
    @State private var editing: String?
    @State private var editText = ""
    @FocusState private var adding: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checklist").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(AppAppearance.blue, in: Circle())
                Text("To-dos").font(.system(size: 16, weight: .semibold)).foregroundStyle(AppAppearance.blue)
                Spacer()
                Text("\(todos.openCount)").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(todos.items) { item in row(item) }
                addRow
            }
            if let message = todos.message {
                HStack(alignment: .top, spacing: 6) {
                    Text(message).font(.system(size: 11)).foregroundStyle(AppAppearance.amber).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { todos.message = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary).accessibilityLabel("Dismiss")
                }
            }
            syncFooter
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }

    private func row(_ item: TodoItem) -> some View {
        HomeTodoRow(item: item, showsPending: todos.config != nil, editing: editing == item.id, editText: $editText,
                    toggle: { withAnimation(.easeOut(duration: 0.18)) { todos.toggle(item) } },
                    beginEdit: { editText = item.text; editing = item.id },
                    commitEdit: { if editing == item.id { todos.edit(item, text: editText); editing = nil } },
                    cancelEdit: { editing = nil },
                    remove: { withAnimation(.easeOut(duration: 0.18)) { todos.remove(item) } })
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 16).foregroundStyle(AppAppearance.tertiary)
            TextField(todos.items.isEmpty ? "What matters today?" : "Add a to-do", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($adding)
                .onSubmit {
                    withAnimation(.easeOut(duration: 0.18)) { todos.add(draft) }
                    draft = ""; adding = true
                }
        }.padding(.vertical, 6)
    }

    @ViewBuilder private var syncFooter: some View {
        HStack(spacing: 5) {
            switch todos.state {
            case .localOnly:
                Image(systemName: "laptopcomputer")
                Text("On this Mac only")
                Text("·")
                SettingsLink { Text("Sync with Maurice") }.buttonStyle(.plain).foregroundStyle(AppAppearance.secondary)
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case .synced(let date):
                Image(systemName: "checkmark.icloud")
                Text("Synced with Maurice")
                Text(date, style: .relative).monospacedDigit()
                Text("ago")
            case .offline:
                Image(systemName: "icloud.slash")
                Text(todos.hasUnsyncedChanges ? "Offline · changes will sync" : "Offline")
            case .failed(let reason):
                Image(systemName: "exclamationmark.icloud")
                Text(reason).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary)
    }
}

private struct HomeTodoRow: View {
    var item: TodoItem
    /// Only meaningful once sync is set up; without it every to-do is local by design.
    var showsPending: Bool
    var editing: Bool
    @Binding var editText: String
    var toggle: () -> Void
    var beginEdit: () -> Void
    var commitEdit: () -> Void
    var cancelEdit: () -> Void
    var remove: () -> Void
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                ZStack {
                    Circle().strokeBorder(item.done ? AppAppearance.green : AppAppearance.hairline, lineWidth: 1.3)
                    if item.done {
                        Circle().fill(AppAppearance.green)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    }
                }.frame(width: 16, height: 16).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Mark not done" : "Mark done")

            if editing {
                TextField("To-do", text: $editText).textFieldStyle(.plain).font(.system(size: 13))
                    .focused($fieldFocused)
                    .onAppear { fieldFocused = true }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commitEdit() } }
                    .onSubmit(commitEdit).onExitCommand(perform: cancelEdit)
            } else {
                Text(item.text).font(.system(size: 13))
                    .strikethrough(item.done, color: AppAppearance.tertiary)
                    .foregroundStyle(item.done ? AppAppearance.tertiary : AppAppearance.text)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEdit)
                    .help("Double-click to edit")
            }
            if showsPending && item.isLocal && !editing {
                Circle().fill(AppAppearance.tertiary).frame(width: 4, height: 4).help("Not synced yet")
            }
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(AppAppearance.tertiary)
                .opacity(hovering && !editing ? 1 : 0).accessibilityLabel("Delete to-do")
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(hovering ? AppAppearance.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(item.done ? "Mark Not Done" : "Mark Done", action: toggle)
            Button("Edit", action: beginEdit)
            Divider()
            Button("Delete", role: .destructive, action: remove)
        }
    }
}

/// Settings → To-dos: connect Burro to Maurice's Convex backend.
struct TodoSyncSection: View {
    @Bindable var todos: TodoStore
    @State private var url = ""
    @State private var token = ""
    @State private var working = false
    var body: some View {
        Section("To-dos") {
            if let config = todos.config {
                LabeledContent("Synced with", value: config.url.host ?? "Convex")
                HStack {
                    Button("Sync Now") { todos.sync() }
                    Button("Disconnect", role: .destructive) { todos.disconnect() }
                }
            } else {
                Button(working ? "Connecting…" : "Import from Maurice") {
                    working = true
                    Task { _ = await todos.importFromMaurice(); working = false }
                }.disabled(working)
                Text("Reads CONVEX_URL and EDGAR_API_TOKEN from ~/Dev/maurice-app/Config/Secrets.xcconfig once, checks them, and stores them in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Enter manually") {
                    TextField("Deployment URL", text: $url, prompt: Text("https://example.convex.cloud"))
                    SecureField("Owner token", text: $token)
                    Button("Connect") {
                        guard let valid = ConvexConfig.validURL(url) else { todos.message = "Use your https://….convex.cloud URL."; return }
                        working = true
                        Task { if await todos.connect(ConvexConfig(url: valid, token: token)) { token = "" }; working = false }
                    }.disabled(working || url.isEmpty || token.count < 16)
                }
            }
            if let message = todos.message { Text(message).font(.caption).foregroundStyle(AppAppearance.amber) }
            Text("To-dos live in Maurice's Convex backend (the todos table) so the Maurice app can show them. Without sync they stay on this Mac and upload once you connect.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
