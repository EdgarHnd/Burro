// The desktop home for accounts, plan limits, pace, quota history and provider controls.
import SwiftUI
import Charts
import BurroCore

extension UsageProvider {
    var color: Color { switch self { case .codex: .green; case .claude: .orange; case .grok: .cyan } }
}
struct UsageDashboardView: View {
    @Bindable var usage: UsageStore
    @State private var settings = false
    @State private var days = 7
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Usage").font(.largeTitle.weight(.semibold))
                    Text("Your accounts. Every limit in one place.").foregroundStyle(.secondary)
                }
                Spacer()
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }.help("Usage settings")
                Button { Task { await usage.refresh(force: true) } } label: {
                    Label(usage.checking ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }.disabled(usage.checking || !usage.enabled)
            }.padding(Layout.inset)
            HStack(spacing: 8) {
                tab("Overview", provider: nil)
                ForEach(UsageProvider.allCases) { provider in tab(provider.title, provider: provider) }
                Spacer()
                Text("Account limits · all machines").font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, Layout.inset).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let message = usage.message {
                        HStack { Label(message, systemImage: "info.circle"); Spacer(); Button { usage.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                            .font(.callout).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !usage.enabled {
                        ContentUnavailableView { Label("Usage is paused", systemImage: "pause.circle") } description: {
                            Text("Connect your coding accounts to see their limits and reset times.")
                        } actions: { Button("Enable usage") { usage.enabled = true } }
                    } else if usage.snapshot.availability == .loading {
                        ForEach(0..<3) { _ in
                            VStack(alignment: .leading, spacing: 16) {
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 160, height: 22)
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 8)
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 220, height: 12)
                            }.padding(22).background(.background, in: RoundedRectangle(cornerRadius: 14))
                        }.accessibilityHidden(true)
                        Text("Loading usage limits…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleProviders) { provider in
                            providerCard(provider)
                        }
                        if visibleProviders.isEmpty {
                            ContentUnavailableView("Provider is paused", systemImage: "pause.circle", description: Text("Enable it in Usage settings."))
                        }
                        if let selected = usage.selected {
                            UsageCostView(provider: selected, profile: usage.preferences.profiles[selected])
                        }
                    }
                    Text("Burro connects directly to each provider. Quotas follow the account shown above; local session activity and token estimates belong to this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(Layout.inset).frame(maxWidth: 1060).frame(maxWidth: .infinity)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $settings) { UsageSettingsView(usage: usage) }
        .task { await usage.refresh() }
    }
    private var visibleProviders: [ProviderUsage] {
        usage.snapshot.providers.filter { usage.selected == nil || $0.id == usage.selected }
    }
    private func tab(_ title: String, provider: UsageProvider?) -> some View {
        Button { usage.selected = provider } label: {
            HStack(spacing: 6) { Image(systemName: provider?.symbol ?? "square.grid.2x2"); Text(title) }
                .font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                .background(usage.selected == provider ? Color.primary.opacity(0.09) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(usage.selected == provider ? .isSelected : [])
    }
    private func providerCard(_ provider: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: provider.id.symbol).font(.title2).foregroundStyle(provider.id.color)
                    .frame(width: 42, height: 42).background(provider.id.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(provider.title).font(.title3.weight(.semibold))
                        if let plan = provider.identity?.plan { Text(plan).font(.caption).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule()) }
                    }
                    Text(provider.identity?.account ?? (provider.isLoading ? "Connecting…" : (provider.issue?.accountLabel ?? "Account identity unavailable")))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(usage.preferences.profiles[provider.id].map { "Profile: \(($0 as NSString).lastPathComponent)" } ?? "From \(provider.id.title == "Claude" ? "Claude Code" : provider.title) on this Mac")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    accountMenu(provider.id)
                    if let date = provider.updatedAt {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            HStack(spacing: 3) {
                                Text(provider.isStale(now: context.date) ? "Stale ·" : "Updated")
                                Text(date, style: .relative); Text("ago")
                            }.font(.caption).foregroundStyle(provider.isStale(now: context.date) ? .orange : .secondary)
                        }
                    }
                }
            }
            if provider.isLoading && provider.windows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 90, height: 12)
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 6)
                }.accessibilityLabel("Loading \(provider.title) limits")
            }
            if let issue = provider.issue, !provider.isLoading {
                HStack(alignment: .top) {
                    Label(issue.message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if provider.id == .claude && issue == .permissionRequired {
                        Button("Connect Claude") { usage.connectClaude() }.disabled(usage.checking)
                    } else if issue.requiresSignIn {
                        Button("Sign in…") { usage.signIn(provider.id) }
                    } else if issue != .rateLimited {
                        Button("Refresh") { Task { await usage.refresh(force: true) } }.disabled(usage.checking)
                    }
                }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 20) {
                    ForEach(provider.windows.filter { usage.preferences.modelLimits || $0.model == nil }) { window in
                        UsageLimitRow(window: window, provider: provider.id, remaining: usage.preferences.remaining,
                            pace: usage.preferences.pace, stale: provider.isStale(now: context.date), now: context.date)
                    }
                }
            }
            if provider.usesClaudeCLI {
                Text("Live limits from Claude Code. Account details, extra controls, and quota history resume when direct access is available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !provider.products.isEmpty {
                HStack(spacing: 16) {
                    ForEach(provider.products) { product in
                        Text("\(product.title) · \(product.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used")
                    }
                }.font(.caption).foregroundStyle(.secondary).help("Product shares of the same subscription quota, not separate limits.")
            }
            if let balance = provider.balance {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(balance.title).font(.callout.weight(.medium))
                        Text(balance.enabled ? "Monthly cap" : "Not enabled").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let used = balance.used, let limit = balance.limit {
                        Text("\(used.formatted(.currency(code: balance.currency))) / \(limit.formatted(.currency(code: balance.currency)))").monospacedDigit()
                    } else { Text("Not reported").foregroundStyle(.secondary) }
                }
            }
            if let credits = provider.resetCredits {
                Label("\(credits) reset credit\(credits == 1 ? "" : "s") available", systemImage: "arrow.counterclockwise.circle").font(.callout)
            }
            if usage.selected != nil, provider.issue == nil { historyChart(provider) }
            Divider()
            HStack(spacing: 18) {
                Link(destination: provider.id.dashboardURL) { Label("Usage dashboard", systemImage: "arrow.up.right") }
                Link(destination: provider.id.statusURL) { Label("Service status", systemImage: "waveform.path.ecg") }
                Spacer()
                if usage.selected == nil { Button("Details") { usage.selected = provider.id }.buttonStyle(.plain).foregroundStyle(provider.id.color) }
            }.font(.callout)
        }.padding(22).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.05)))
    }
    private func accountMenu(_ provider: UsageProvider) -> some View {
        Menu {
            Button("Sign in / switch account…") { usage.signIn(provider) }
            Button("Choose existing profile…") { usage.selectProfile(provider) }
            if usage.preferences.profiles[provider] != nil { Button("Use default account") { usage.preferences.profiles.removeValue(forKey: provider) } }
            if provider == .claude { Button("Allow Claude Keychain access…") { usage.connectClaude() } }
        } label: { Label("Account", systemImage: "person.crop.circle") }.fixedSize()
    }
    @ViewBuilder private func historyChart(_ provider: ProviderUsage) -> some View {
        let samples = usage.history.filter { $0.provider == provider.id && $0.account == provider.identity?.scope && $0.date >= Date().addingTimeInterval(Double(-days) * 86400) }
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack {
                Text("Quota history").font(.headline)
                Spacer()
                Picker("Period", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30) }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            if !usage.preferences.history || samples.count < 2 {
                Text(usage.preferences.history ? "History starts with Burro’s readings for this account. The chart appears after the next refresh." : "History is off. Enable it in Usage settings.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            } else {
                Chart {
                    ForEach(samples) { sample in
                        ForEach(sample.windows) { window in
                            if let remaining = window.remainingPercent {
                                LineMark(x: .value("Time", sample.date), y: .value("Remaining", remaining), series: .value("Limit", window.id))
                                    .foregroundStyle(by: .value("Limit", window.title)).interpolationMethod(.stepEnd)
                            }
                        }
                    }
                }.chartYScale(domain: 0...100).chartYAxisLabel("% remaining").frame(height: 180)
                Text("Readings are stored only on this Mac, separately for each verified account.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageLimitRow: View {
    var window: UsageWindow
    var provider: UsageProvider
    var remaining: Bool
    var pace: Bool
    var stale: Bool
    var now: Date
    var body: some View {
        let uncertain = stale || window.isExpired(now: now)
        let quota = window.remainingPercent
        let estimate = uncertain ? nil : UsagePace(window: window, now: now)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.title).font(.callout.weight(.semibold))
                Spacer()
                if let quota {
                    Text("\(Int((remaining ? quota : 100 - quota).rounded()))% \(uncertain ? "last seen" : (remaining ? "left" : "used"))").font(.callout.weight(.semibold)).monospacedDigit()
                } else { Text("Unavailable").foregroundStyle(.secondary) }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    if let quota { Capsule().fill(uncertain ? .gray : (quota <= 10 ? .red : provider.color)).frame(width: geometry.size.width * (remaining ? quota : 100 - quota) / 100) }
                    if pace, let estimate {
                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.6)).frame(width: 2, height: 12)
                            .offset(x: max(0, geometry.size.width * (remaining ? estimate.expectedRemaining : 100 - estimate.expectedRemaining) / 100 - 1))
                    }
                }
            }.frame(height: 6).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text(window.resetLabel(now: now)).help(window.resetsAt?.formatted() ?? "Reset unavailable")
                Spacer()
                if pace, let estimate {
                    Text("\(Int(abs(estimate.reserve).rounded()))% \(estimate.reserve >= 0 ? "reserve" : "ahead of pace")")
                        .foregroundStyle(estimate.reserve >= 0 ? Color.secondary : Color.orange)
                        .help("Linear estimate based on elapsed time in this limit window. Workload and provider rules can change.")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct UsageSettingsView: View {
    @Bindable var usage: UsageStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Usage settings").font(.title2.weight(.semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
            Form {
                Section("Providers") {
                    ForEach(UsageProvider.allCases) { provider in
                        Toggle(provider.title, isOn: Binding(get: { usage.preferences.providers.contains(provider) }, set: { enabled in
                            if enabled { usage.preferences.providers.insert(provider) } else { usage.preferences.providers.remove(provider) }
                        }))
                    }
                }
                Section("Display") {
                    Picker("Refresh", selection: $usage.preferences.interval) { Text("Every minute").tag(60); Text("Every 5 minutes").tag(300); Text("Every 15 minutes").tag(900) }
                    Toggle("Show remaining instead of used", isOn: $usage.preferences.remaining)
                    Toggle("Show linear pace estimates", isOn: $usage.preferences.pace)
                    Toggle("Show separate model limits", isOn: $usage.preferences.modelLimits)
                    Text("The notch always shows remaining limits, including separate model quotas.").font(.caption).foregroundStyle(.secondary)
                }
                Section("History") {
                    Toggle("Keep 30 days of quota readings on this Mac", isOn: $usage.preferences.history)
                    Button("Clear quota history", role: .destructive) { usage.clearHistory() }
                    Text("Only quota readings and a hashed account identifier are saved. Turning history off deletes saved readings.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.frame(width: 470, height: 560)
    }
}
