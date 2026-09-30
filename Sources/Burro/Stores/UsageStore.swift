// Independent provider polling, account selection, preferences and private aggregate history.
import AppKit
import Observation
import BurroCore

struct UsagePreferences: Codable, Equatable {
    var providers: Set<UsageProvider> = Set(UsageProvider.allCases)
    var interval = 300
    var remaining = true
    var pace = true
    var modelLimits = true
    var history = true
    var profiles: [UsageProvider: String] = [:]
}

@MainActor @Observable final class UsageStore {
    var snapshot = ProviderUsageSnapshot.loading
    var checking = false
    var enabled: Bool { didSet {
        defaults.set(enabled, forKey: "usageEnabled"); invalidate()
    } }
    var preferences: UsagePreferences { didSet {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "usagePreferences") }
        if !preferences.history { clearHistory() }
        if preferences.providers != oldValue.providers || preferences.profiles != oldValue.profiles { invalidate() }
        else if preferences.interval != oldValue.interval { nextPoll = [:] }
    } }
    var history: [UsageHistorySample]
    var selected: UsageProvider? = nil
    var message: String?
    private let defaults: UserDefaults
    private var signingIn: (provider: UsageProvider, previousScope: String?)?
    private var generation = 0
    private var lastAttempt: Date?
    private var nextPoll: [UsageProvider: Date] = [:]
    private var failures: [UsageProvider: Int] = [:]
    private var monitor: Task<Void, Never>?
    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Burro/usage-history.json")
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "usageEnabled") as? Bool ?? true
        var loaded = defaults.data(forKey: "usagePreferences").flatMap { try? JSONDecoder().decode(UsagePreferences.self, from: $0) } ?? UsagePreferences()
        loaded.interval = [60, 300, 900].contains(loaded.interval) ? loaded.interval : 300
        preferences = loaded
        if loaded.history, let size = try? Self.historyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size < 24 * 1024 * 1024, let data = try? Data(contentsOf: Self.historyURL),
           let decoded = try? JSONDecoder().decode([UsageHistorySample].self, from: data) {
            history = UsageHistorySample.retaining(decoded)
        } else { history = [] }
        if !enabled { snapshot = .disabled }
    }
    func start() {
        guard monitor == nil else { return }
        monitor = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    private func invalidate() {
        generation += 1; lastAttempt = nil; nextPoll = [:]; failures = [:]
        snapshot = enabled ? .loading : .disabled
        Task { await refresh() }
    }
    func refresh(force: Bool = false, allowClaudePrompt: Bool = false) async {
        guard enabled, !checking else { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < 15 { return }
        let due = preferences.providers.filter { provider in
            let ready = (nextPoll[provider] ?? .distantPast) <= Date()
            // Manual refresh must not hammer a provider that explicitly asked us to wait.
            if snapshot.providers.first(where: { $0.id == provider })?.issue == .rateLimited { return ready }
            return force || ready
        }
        guard !due.isEmpty else { return }
        checking = true; lastAttempt = Date()
        let ticket = generation, prefs = preferences
        let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            .map { $0.appendingPathComponent("Contents/Resources/codex").path }
        let executable = CodexUsageReader.executable(bundled: bundle)
        let order = UsageProvider.allCases.filter { prefs.providers.contains($0) }
        let placeholders = order.map { provider in
            var value = snapshot.providers.first(where: { $0.id == provider }) ?? .loading(provider)
            value.isLoading = due.contains(provider)
            return value
        }
        snapshot = .init(availability: .available, providers: placeholders)
        let results = await withTaskGroup(of: ProviderUsage.self, returning: [ProviderUsage].self) { group in
            for provider in UsageProvider.allCases where due.contains(provider) {
                let profile = prefs.profiles[provider]
                group.addTask {
                    switch provider {
                    case .codex: return await Task.detached(priority: .utility) { CodexUsageReader.read(executable: executable, home: profile) }.value
                    case .claude: return await ClaudeUsageReader.read(allowKeychainPrompt: allowClaudePrompt, profile: profile)
                    case .grok: return await GrokUsageReader.read(profile: profile)
                    }
                }
            }
            var values: [ProviderUsage] = []
            for await value in group {
                values.append(value)
                if enabled && ticket == generation {
                    failures[value.id] = value.issue == nil ? 0 : (failures[value.id] ?? 0) + 1
                    nextPoll[value.id] = Date().addingTimeInterval(UsageRetryPolicy.delay(issue: value.issue, failures: failures[value.id] ?? 0, interval: prefs.interval))
                    snapshot = .init(availability: .available, providers: order.compactMap { id in
                        values.first(where: { $0.id == id }) ?? placeholders.first(where: { $0.id == id })
                    })
                }
            }
            return values.sorted { UsageProvider.allCases.firstIndex(of: $0.id)! < UsageProvider.allCases.firstIndex(of: $1.id)! }
        }
        if enabled && ticket == generation {
            snapshot = .init(availability: .available, providers: order.compactMap { id in
                results.first(where: { $0.id == id }) ?? placeholders.first(where: { $0.id == id })
            })
            if let pending = signingIn, let identity = results.first(where: { $0.id == pending.provider })?.identity,
               identity.scope != pending.previousScope {
                message = "Connected to \(identity.account)."; signingIn = nil
            }
            if prefs.history {
                history = UsageHistorySample.retaining(history + results.compactMap(UsageHistorySample.init))
                saveHistory()
            }
        }
        checking = false
        if enabled && ticket != generation { await refresh() }
    }
    func connectClaude() {
        guard !checking else { return }
        lastAttempt = nil
        Task { await refresh(force: true, allowClaudePrompt: true) }
    }
    func clearHistory() {
        history = []; try? FileManager.default.removeItem(at: Self.historyURL)
    }
    private func saveHistory() {
        do {
            let url = Self.historyURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(history).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { message = "History couldn’t be saved. Live limits are still available." }
    }
    func selectProfile(_ provider: UsageProvider) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
        panel.message = "Choose an existing \(provider.title) profile folder. Burro reads that account’s sign-in without changing your default account."
        panel.prompt = "Use profile"
        if panel.runModal() == .OK, let url = panel.url { preferences.profiles[provider] = url.path }
    }
    func signIn(_ provider: UsageProvider) {
        guard let executable = Self.executable(provider) else { message = "Install the \(provider.title) command-line app first."; return }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(provider.title)"
        alert.informativeText = "This opens the official \(provider.title) sign-in in Terminal. It changes the account used by \(preferences.profiles[provider] == nil ? "your local coding app" : "the selected profile"). Complete sign-in, then refresh Burro."
        alert.addButton(withTitle: "Continue to sign in"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burro-signin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent("Sign in to \(provider.title).command")
            let envName = provider == .codex ? "CODEX_HOME" : (provider == .claude ? "CLAUDE_CONFIG_DIR" : "GROK_HOME")
            let env = preferences.profiles[provider].map { "export \(envName)=\(Self.quote($0))\n" } ?? ""
            let args = provider == .claude ? "auth login --claudeai" : (provider == .grok ? "login --oauth" : "login")
            let script = "#!/bin/zsh\n" + env + "\(Self.quote(executable)) \(args)\nresult=$?\n/bin/rm -- \(Self.quote(url.path))\n/bin/rmdir -- \(Self.quote(folder.path))\nexit $result\n"
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            signingIn = (provider, snapshot.providers.first(where: { $0.id == provider })?.identity?.scope)
            // Invalidate before changing accounts so previous totals cannot appear under a new identity.
            invalidate()
            NSWorkspace.shared.open(url)
            message = "Finish \(provider.title) sign-in in Terminal, then refresh here."
        } catch { message = "Couldn’t open sign-in. Run the provider’s login command in Terminal, then refresh." }
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func executable(_ provider: UsageProvider) -> String? {
        if provider == .codex {
            return CodexUsageReader.executable(bundled: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.appendingPathComponent("Contents/Resources/codex").path)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/" + provider.rawValue, "/opt/homebrew/bin/" + provider.rawValue, "/usr/local/bin/" + provider.rawValue]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
