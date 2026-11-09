// Start a Codex or Claude chat in one of your projects. Choices are remembered between launches.
import AppKit
import SwiftUI
import BurroCore

struct NewChatSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("launch.provider") private var providerRaw = LaunchProvider.codex.rawValue
    @AppStorage("launch.access") private var accessRaw = LaunchAccess.ask.rawValue
    @AppStorage("launch.model.codex") private var codexModel = ""
    @AppStorage("launch.model.claude") private var claudeModel = "claude-opus-5-5"
    @AppStorage("launch.effort.codex") private var codexEffort = ""
    @AppStorage("launch.effort.claude") private var claudeEffort = ""
    @AppStorage("launch.open") private var openWhenStarted = true
    @AppStorage("launch.folder") private var savedFolder = ""
    @State private var prompt = ""
    @State private var folder = ""
    @State private var customFolders: [String] = []
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    private var provider: LaunchProvider { LaunchProvider(rawValue: providerRaw) ?? .codex }
    private var access: LaunchAccess { LaunchAccess(rawValue: accessRaw) ?? .ask }
    private var models: [LaunchModel] { provider == .codex ? store.codexModels : LaunchModel.claude }
    private var modelBinding: Binding<String> { provider == .codex ? $codexModel : $claudeModel }
    private var effortBinding: Binding<String> { provider == .codex ? $codexEffort : $claudeEffort }
    private var selectedModel: LaunchModel? {
        models.first { $0.id == modelBinding.wrappedValue } ?? (modelBinding.wrappedValue.isEmpty ? models.first(where: \.isDefault) : nil)
    }
    private var folders: [(path: String, name: String)] {
        let known = store.launchFolders
        let extra = customFolders.filter { path in !known.contains { $0.path == path } }
            .map { (path: $0, name: URL(fileURLWithPath: $0).lastPathComponent) }
        return known + extra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("New chat").font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("Agent", selection: $providerRaw) {
                    ForEach(LaunchProvider.allCases) { Text($0.title).tag($0.rawValue) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .focused($promptFocused)
                    .padding(10)
                if prompt.isEmpty {
                    Text("What should \(provider == .codex ? "Codex" : "Claude") do?")
                        .font(.system(size: 14)).foregroundStyle(AppAppearance.tertiary)
                        .padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
                }
            }
            .frame(minHeight: 130)
            .background(AppAppearance.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(promptFocused ? AppAppearance.hairline : AppAppearance.separator))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    label("Project")
                    Picker("Project", selection: $folder) {
                        ForEach(folders, id: \.path) { Text($0.name).tag($0.path).help($0.path) }
                        Divider()
                        Text("Choose folder…").tag("__choose__")
                    }.labelsHidden().frame(maxWidth: 320, alignment: .leading)
                }
                GridRow {
                    label("Model")
                    HStack(spacing: 10) {
                        Picker("Model", selection: modelBinding) {
                            if provider == .codex { Text(store.codexModels.isEmpty ? "Default (loading models…)" : "Default").tag("") }
                            ForEach(models) { Text($0.title).tag($0.id) }
                        }.labelsHidden().fixedSize()
                        if let efforts = selectedModel?.efforts, !efforts.isEmpty {
                            Picker("Effort", selection: effortBinding) {
                                Text("Default effort").tag("")
                                ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                            }.labelsHidden().fixedSize()
                        }
                    }
                }
                GridRow {
                    label("Access")
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Access", selection: $accessRaw) {
                            ForEach(LaunchAccess.allCases) { Text($0.title).tag($0.rawValue) }
                        }.labelsHidden().fixedSize()
                        Text(access.detail).font(.system(size: 11)).foregroundStyle(AppAppearance.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    label("Machine")
                    HStack(spacing: 6) {
                        Image(systemName: "laptopcomputer").foregroundStyle(AppAppearance.secondary)
                        Text("This Mac")
                        if !store.remoteHosts.isEmpty {
                            Text("· other machines are coming next").foregroundStyle(AppAppearance.tertiary)
                        }
                    }.font(.system(size: 12))
                }
            }

            Toggle(provider == .codex ? "Open in Codex when it starts" : "Attach in Terminal when it starts", isOn: $openWhenStarted)
                .toggleStyle(.checkbox).font(.system(size: 12))

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(AppAppearance.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("It shows up in Home and the notch like any other chat.").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { start() } label: {
                    HStack(spacing: 6) {
                        if store.launching { ProgressView().controlSize(.mini) }
                        Text(store.launching ? "Starting…" : "Start chat")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.launching || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .modifier(AppTheme())
        .onAppear {
            store.loadCodexModels()
            folder = folders.contains { $0.path == savedFolder } ? savedFolder : (folders.first?.path ?? "")
            promptFocused = true
        }
        .onChange(of: folder) { old, new in
            if new == "__choose__" { folder = old; chooseFolder() } else if !new.isEmpty { savedFolder = new }
        }
        .onChange(of: modelBinding.wrappedValue) { _, _ in effortBinding.wrappedValue = "" }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary).gridColumnAlignment(.trailing)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customFolders.append(url.path); folder = url.path
    }

    private func start() {
        error = nil
        let request = LaunchRequest(provider: provider, prompt: prompt, folder: folder,
                                    model: modelBinding.wrappedValue.isEmpty ? nil : modelBinding.wrappedValue,
                                    effort: effortBinding.wrappedValue.isEmpty ? nil : effortBinding.wrappedValue,
                                    access: access)
        Task {
            do {
                _ = try await store.startChat(request, openWhenStarted: openWhenStarted)
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn't start the chat."
            }
        }
    }
}
