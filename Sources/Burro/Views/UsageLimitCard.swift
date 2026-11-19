// One provider's limits on the Usage page (a section of the joined Limits panel, `framed: false`): its name, plan, account and where the reading comes from,
// the Account menu (sign in or switch, choose a profile, default account, Claude Keychain access),
// when it was read (marked stale after ten minutes), any problem with its action (Connect Claude,
// Sign in…, Refresh), then each limit as a wide meter: what is left (or used, per Usage settings),
// a tick where even pacing would be, the reset, and the "at this pace" forecast (UsageForecast).
// Extra usage, reset credits, product shares and the Claude Code fallback caveat follow, then
// links to the provider's usage dashboard and status page and the quota history chart on request.
// Last, the collapsed "Local history (30 days)" (UsageLocalHistory.swift): this Mac's tokens and
// estimated API value for the selected profile, read only when the owner opens it.
import SwiftUI
import Charts
import BurroCore

struct UsageLimitCard: View {
    @Bindable var usage: UsageStore
    var provider: ProviderUsage
    var alerts: [UsageAlert]
    var now: Date
    var calendar: Calendar
    var compact: Bool
    var localHistory: UsageLocalHistoryState = .shared
    /// false inside the page's joined Limits panel: no surface or padding of its own.
    var framed = true
    @State private var showHistory = false
    @State private var days = 7

    private var stale: Bool { provider.isStale(now: now) }
    private var windows: [UsageWindow] { provider.windows.filter { usage.preferences.modelLimits || $0.model == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.top, 14).padding(.bottom, 4)
            if provider.isLoading && provider.windows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 3).fill(AppAppearance.raised).frame(width: 90, height: 12)
                    RoundedRectangle(cornerRadius: 6).fill(AppAppearance.raised).frame(height: 12)
                }.padding(.vertical, 12).accessibilityLabel("Loading \(provider.title) limits")
            }
            if let issue = provider.issue, !provider.isLoading { issueBox(issue).padding(.vertical, 8) }
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 { Rectangle().fill(AppAppearance.separator).frame(height: 1) }
                UsageLimitMeter(window: window, providerTitle: provider.title, forecast: UsageForecast(window: window, now: now, stale: stale),
                                alert: alerts.contains { $0.provider == provider.id && $0.windowID == window.id },
                                remaining: usage.preferences.remaining, pace: usage.preferences.pace, now: now, calendar: calendar, compact: compact)
            }
            extras
            footer.padding(.top, 10).padding(.bottom, 12)
            if showHistory { historyChart.padding(.bottom, 16) }
            UsageLocalHistorySection(state: localHistory, provider: provider.id, profile: usage.preferences.profiles[provider.id],
                                     now: now, calendar: calendar)
        }
        .padding(.horizontal, framed ? 20 : 0)
        .modifier(FramedSurface(framed: framed))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(provider.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(AppAppearance.text)
            if let plan = provider.identity?.plan { Text(plan).font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary) }
            Text(account).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled).layoutPriority(-1)
            Spacer(minLength: 8)
            if let date = provider.updatedAt {
                Text(stale ? "Stale · read \(UsageClock.span(now.timeIntervalSince(date))) ago" : (UsagePageText.updated(date, now: now) ?? ""))
                    .font(.system(size: 12, weight: stale ? .semibold : .regular))
                    .foregroundStyle(stale ? AppAppearance.amber : AppAppearance.tertiary)
                    .help(stale ? "This reading is more than ten minutes old, so no forecast is made from it." : date.formatted())
            }
            accountMenu
        }
    }

    /// "you@example.com · Profile: work" or "· From Claude Code on this Mac".
    private var account: String {
        let who = provider.identity?.account ?? (provider.isLoading ? "Connecting…" : (provider.issue?.accountLabel ?? "Account identity unavailable"))
        let source = usage.preferences.profiles[provider.id].map { "Profile: \(($0 as NSString).lastPathComponent)" }
            ?? "From \(provider.id == .claude ? "Claude Code" : provider.title) on this Mac"
        return "· \(who) · \(source)"
    }

    private var accountMenu: some View {
        Menu {
            Button("Sign in / switch account…") { usage.signIn(provider.id) }
            Button("Choose existing profile…") { usage.selectProfile(provider.id) }
            if usage.preferences.profiles[provider.id] != nil { Button("Use default account") { usage.preferences.profiles.removeValue(forKey: provider.id) } }
            if provider.id == .claude { Button("Allow Claude Keychain access…") { usage.connectClaude() } }
        } label: { Label("Account", systemImage: "person.crop.circle").font(.system(size: 12, weight: .medium)) }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(AppAppearance.hairline))
            .help("Sign in, switch account or choose a profile for \(provider.title)")
    }

    private func issueBox(_ issue: UsageIssue) -> some View {
        HStack(alignment: .top) {
            Label(issue.message, systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if provider.id == .claude && issue == .permissionRequired {
                Button("Connect Claude") { usage.connectClaude() }.disabled(usage.checking)
            } else if issue.requiresSignIn {
                Button("Sign in…") { usage.signIn(provider.id) }
            } else if issue != .rateLimited {
                Button("Refresh") { Task { await usage.refresh(force: true) } }.disabled(usage.checking)
            }
        }.padding(12).background(AppAppearance.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var extras: some View {
        let caption = Font.system(size: 12)
        VStack(alignment: .leading, spacing: 8) {
            if let balance = provider.balance {
                HStack {
                    Text(balance.title).font(.system(size: 13, weight: .medium))
                    Text(balance.enabled ? "Monthly cap" : "Not enabled").font(caption).foregroundStyle(AppAppearance.tertiary)
                    Spacer()
                    if let used = balance.used, let limit = balance.limit {
                        Text("\(used.formatted(.currency(code: balance.currency))) / \(limit.formatted(.currency(code: balance.currency)))").monospacedDigit()
                    } else { Text("Not reported").foregroundStyle(AppAppearance.secondary) }
                }.font(.system(size: 13))
            }
            if let credits = provider.resetCredits {
                Label("\(credits) reset credit\(credits == 1 ? "" : "s") available", systemImage: "arrow.counterclockwise.circle")
                    .font(caption).foregroundStyle(AppAppearance.secondary)
            }
            if !provider.products.isEmpty {
                HStack(spacing: 16) {
                    ForEach(provider.products) { product in
                        Text("\(product.title) · \(product.usedPercent.formatted(.number.precision(.fractionLength(0...1))))% used")
                    }
                }.font(caption).foregroundStyle(AppAppearance.secondary).help("Product shares of the same subscription quota, not separate limits.")
            }
            if provider.usesClaudeCLI {
                Text("Live limits from Claude Code. Account details, extra controls, and quota history resume when direct access is available.")
                    .font(caption).foregroundStyle(AppAppearance.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.top, provider.balance == nil && provider.resetCredits == nil && provider.products.isEmpty && !provider.usesClaudeCLI ? 0 : 10)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Link(destination: provider.id.dashboardURL) { Label("Usage dashboard", systemImage: "arrow.up.right") }
            Link(destination: provider.id.statusURL) { Label("Service status", systemImage: "waveform.path.ecg") }
            Spacer()
            if provider.issue == nil && !provider.usesClaudeCLI && !provider.isLoading && provider.identity != nil {
                Button(showHistory ? "Hide quota history" : "Quota history") { showHistory.toggle() }.buttonStyle(.plain)
                    .foregroundStyle(AppAppearance.secondary)
                    .help("Remaining percentage over time for this account, from Burro’s own readings")
            }
        }.font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
    }

    @ViewBuilder private var historyChart: some View {
        let samples = usage.history.filter { $0.provider == provider.id && $0.account == provider.identity?.scope && $0.date >= now.addingTimeInterval(Double(-days) * 86400) }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quota history").font(.system(size: 13, weight: .semibold))
                Spacer()
                CapsulePicker(options: [(7, "7 days"), (30, "30 days")], selection: $days)
            }
            if !usage.preferences.history || samples.count < 2 {
                Text(usage.preferences.history ? "History starts with Burro’s readings for this account. The chart appears after the next refresh." : "History is off. Enable it in Usage settings.")
                    .font(.system(size: 13)).foregroundStyle(AppAppearance.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
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
                }.chartYScale(domain: 0...100).chartYAxisLabel("% remaining").frame(height: 160)
                Text("Readings are stored only on this Mac, separately for each verified account.").font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
            }
        }
    }
}

/// A card surface only when framed.
private struct FramedSurface: ViewModifier {
    var framed: Bool
    func body(content: Content) -> some View {
        if framed { content.modifier(AppCardSurface()) } else { content }
    }
}

/// One limit as a wide meter row: label, bar with the even-pace tick, the percentage, reset and forecast.
struct UsageLimitMeter: View {
    var window: UsageWindow
    var providerTitle: String
    var forecast: UsageForecast
    /// The page leads with this window (UsageAlert).
    var alert: Bool
    var remaining: Bool
    var pace: Bool
    var now: Date
    var calendar: Calendar
    var compact: Bool

    private var uncertain: Bool { forecast.outcome == .stale || forecast.outcome == .awaitingReset }
    private var shown: Double? { forecast.left.map { remaining ? $0 : 100 - $0 } }
    private var tick: Double? { pace ? forecast.evenPaceLeft.map { remaining ? $0 : 100 - $0 } : nil }
    private var fill: Color {
        if uncertain { return AppAppearance.tertiary }
        if alert || forecast.isShort || (forecast.left ?? 100) <= UsageAlert.lowLeft { return AppAppearance.amber }
        return AppAppearance.green
    }
    private var label: String {
        if window.title.lowercased().hasPrefix("session"), let duration = window.duration, duration >= 3600 {
            let hours = Int((duration / 3600).rounded())
            return window.title + " · \(hours) hour\(hours == 1 ? "" : "s")"
        }
        return window.title
    }
    private var forecastText: String { UsageClock.forecast(forecast, now: now, calendar: calendar) }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) { title; Spacer(); percent }
                    bar
                    HStack(alignment: .firstTextBaseline) { reset; Spacer(); forecastLine }
                }
            } else {
                HStack(spacing: 16) {
                    title.frame(width: 160, alignment: .leading)
                    bar.frame(maxWidth: .infinity)
                    percent.frame(width: 70, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) { reset; forecastLine }.frame(width: 250, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(providerTitle) \(window.title)")
        .accessibilityValue(accessibilityValue)
    }

    private var title: some View {
        Text(label).font(.system(size: 13, weight: alert ? .semibold : .regular)).foregroundStyle(AppAppearance.text)
            .lineLimit(1).truncationMode(.tail)
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AppAppearance.raised)
                if let shown, shown > 0 {
                    Capsule().fill(fill).frame(width: max(6, geometry.size.width * min(100, shown) / 100))
                }
                if let tick {
                    Rectangle().fill(AppAppearance.text.opacity(0.55)).frame(width: 2, height: 18)
                        .offset(x: min(geometry.size.width - 2, max(0, geometry.size.width * tick / 100 - 1)))
                }
            }.frame(height: 12).frame(maxHeight: .infinity)
        }
        .frame(height: 18)
        .help(tick == nil ? "" : "The tick is where this limit would be if it were used evenly across the window.")
    }

    @ViewBuilder private var percent: some View {
        if let shown {
            VStack(alignment: compact ? .leading : .trailing, spacing: 0) {
                Text("\(Int(shown.rounded()))%").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(uncertain ? AppAppearance.secondary : (alert ? AppAppearance.amber : AppAppearance.text))
                if uncertain || !remaining {
                    Text(uncertain ? "last seen" : "used").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                }
            }.fixedSize()
        } else {
            Text("Unavailable").font(.system(size: 12)).foregroundStyle(AppAppearance.secondary)
        }
    }

    private var reset: some View {
        Text(UsageClock.reset(window.resetsAt, duration: window.duration, now: now, calendar: calendar))
            .font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary).lineLimit(1)
            .help(window.resetsAt?.formatted() ?? "Reset unavailable")
    }

    @ViewBuilder private var forecastLine: some View {
        if pace {
            Text(forecastText).font(.system(size: 12.5)).lineLimit(1)
                .foregroundStyle(forecast.isShort ? AppAppearance.amber : AppAppearance.tertiary)
                .help(help)
        }
    }

    private var help: String {
        switch forecast.outcome {
        case .stale: "No forecast: this reading is more than ten minutes old."
        case .awaitingReset: "No forecast: the reset time has passed and the provider hasn’t reported the refill yet."
        case .unknown: "No forecast: the provider didn’t report when this window started or resets."
        case .tooEarly: "No forecast yet: this window began too recently for its pace to mean anything."
        default: "A straight-line guess from the share used and the share of the window gone. Your workload and provider rules can change it."
        }
    }

    private var accessibilityValue: String {
        var parts = [shown.map { "\(Int($0.rounded()))% \(uncertain ? "last seen" : (remaining ? "left" : "used"))" } ?? "unavailable"]
        parts.append(UsageClock.reset(window.resetsAt, duration: window.duration, now: now, calendar: calendar))
        if pace && forecastText != "—" { parts.append(forecastText) }
        return parts.joined(separator: ", ")
    }
}
