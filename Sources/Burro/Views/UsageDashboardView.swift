// The desktop home for accounts, plan limits, pace, quota history and provider controls.
import SwiftUI
import Charts
import BurroCore

extension UsageProvider {
    var color: Color { switch self { case .codex: AppAppearance.green; case .claude: AppAppearance.claude; case .grok: AppAppearance.blue } }
}
struct UsageDashboardView: View {
    @Bindable var usage: UsageStore
    @State private var settings = false
    @State private var days = 7
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Usage").font(AppAppearance.pageTitle)
                    Text("Your accounts. Every limit in one place.").font(.caption).foregroundStyle(AppAppearance.secondary)
                }
                Spacer()
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }.help("Usage settings")
                Button { Task { await usage.refresh(force: true) } } label: {
                    Label(usage.checking ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }.disabled(usage.checking || !usage.enabled)
            }.padding(Layout.inset)
            HStack(spacing: 12) {
                HStack(spacing: 3) {
                    tab("Overview", provider: nil)
                    ForEach(UsageProvider.allCases) { provider in tab(provider.title, provider: provider) }
                }.padding(3).background(AppAppearance.raised, in: Capsule())
                Spacer()
                Text("Account limits · all machines").font(.caption).foregroundStyle(AppAppearance.secondary)
            }.padding(.horizontal, Layout.inset).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = usage.message {
                        HStack { Label(message, systemImage: "info.circle"); Spacer(); Button { usage.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                            .font(.callout).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !usage.enabled {
                        AppEmptyState(title: "Usage is paused", symbol: "pause.circle",
                            detail: "Connect your coding accounts to see their limits and reset times.") {
                            Button("Enable usage") { usage.enabled = true }
                        }
                    } else if usage.snapshot.availability == .loading {
                        ForEach(0..<3) { _ in
                            VStack(alignment: .leading, spacing: 16) {
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 160, height: 22)
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 8)
                                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 220, height: 12)
                            }.padding(16).modifier(AppCardSurface())
                        }.accessibilityHidden(true)
                        Text("Loading usage limits…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleProviders) { provider in
                            providerCard(provider)
                        }
                        if visibleProviders.isEmpty {
                            AppEmptyState("Provider is paused", symbol: "pause.circle", detail: "Enable it in Usage settings.")
                        }
                        if let selected = usage.selected {
                            UsageCostView(provider: selected, profile: usage.preferences.profiles[selected])
                        }
                    }
                    Text("Burro connects directly to each provider. Quotas follow the account shown above; local session activity and token estimates belong to this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(Layout.inset).frame(maxWidth: 1060).frame(maxWidth: .infinity)
            }
        }
        .modifier(AppTheme())
        .sheet(isPresented: $settings) { UsageSettingsView(usage: usage) }
        .task { await usage.refresh() }
    }
    private var visibleProviders: [ProviderUsage] {
        usage.snapshot.providers.filter { usage.selected == nil || $0.id == usage.selected }
    }
    private func tab(_ title: String, provider: UsageProvider?) -> some View {
        Button { usage.selected = provider } label: {
            HStack(spacing: 6) { Image(systemName: provider?.symbol ?? "square.grid.2x2"); Text(title) }
                .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(usage.selected == provider ? AppAppearance.text : AppAppearance.secondary)
                .background(usage.selected == provider ? AppAppearance.background : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(usage.selected == provider ? .isSelected : [])
    }
    private func providerCard(_ provider: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ProviderBadge(symbol: provider.id.symbol, color: provider.id.color)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(provider.title).font(AppAppearance.sectionTitle)
                        if let plan = provider.identity?.plan { Text(plan).font(.caption.weight(.semibold)).foregroundStyle(AppAppearance.secondary).padding(.horizontal, 7).padding(.vertical, 2).background(AppAppearance.raised, in: Capsule()) }
                    }
                    Text(provider.identity?.account ?? (provider.isLoading ? "Connecting…" : (provider.issue?.accountLabel ?? "Account identity unavailable")))
                        .font(.callout.weight(.medium)).foregroundStyle(AppAppearance.secondary).textSelection(.enabled)
                    Text(usage.preferences.profiles[provider.id].map { "Profile: \(($0 as NSString).lastPathComponent)" } ?? "From \(provider.id.title == "Claude" ? "Claude Code" : provider.title) on this Mac")
                        .font(.caption).foregroundStyle(AppAppearance.secondary)
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
        }.padding(16).modifier(AppCardSurface())
    }
    private func accountMenu(_ provider: UsageProvider) -> some View {
        Menu {
            Button("Sign in / switch account…") { usage.signIn(provider) }
            Button("Choose existing profile…") { usage.selectProfile(provider) }
            if usage.preferences.profiles[provider] != nil { Button("Use default account") { usage.preferences.profiles.removeValue(forKey: provider) } }
            if provider == .claude { Button("Allow Claude Keychain access…") { usage.connectClaude() } }
        } label: { Label("Account", systemImage: "person.crop.circle").font(.callout.weight(.semibold)) }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10).padding(.vertical, 5)
            .background(AppAppearance.raised, in: Capsule())
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
                Text(window.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(AppAppearance.secondary)
                Spacer()
                if let quota {
                    (Text("\(Int((remaining ? quota : 100 - quota).rounded()))").font(.system(size: 16, weight: .semibold, design: .rounded))
                     + Text("% ").font(.system(size: 12, weight: .semibold))
                     + Text(uncertain ? "last seen" : (remaining ? "left" : "used")).font(.system(size: 12, weight: .semibold)))
                        .monospacedDigit().foregroundStyle(uncertain ? AppAppearance.secondary : AppAppearance.text)
                } else { Text("Unavailable").foregroundStyle(.secondary) }
            }
            UsageQuotaBar(percent: quota.map { remaining ? $0 : 100 - $0 }, remaining: quota, stale: uncertain,
                          marker: pace ? estimate.map { remaining ? $0.expectedRemaining : 100 - $0.expectedRemaining } : nil)
            HStack(alignment: .firstTextBaseline) {
                Text(window.resetLabel(now: now)).help(window.resetsAt?.formatted() ?? "Reset unavailable")
                Spacer()
                if pace, let estimate {
                    Text("\(Int(abs(estimate.reserve).rounded()))% \(estimate.reserve >= 0 ? "reserve" : "ahead of pace")")
                        .fontWeight(.semibold)
                        .foregroundStyle(estimate.reserve >= 0 ? AppAppearance.green : AppAppearance.amber)
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
            HStack { Text("Usage settings").font(AppAppearance.pageTitle); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(20)
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
            }.formStyle(.grouped).scrollContentBackground(.hidden)
        }.frame(width: 470, height: 560).modifier(AppTheme())
    }
}
