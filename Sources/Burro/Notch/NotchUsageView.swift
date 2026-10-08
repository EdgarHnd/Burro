// Quotas stay separate from live agent status; every provider retains its own snapshot age and resets.
import SwiftUI
import BurroCore

struct NotchUsageView: View {
    var snapshot: ProviderUsageSnapshot
    var enabled: Bool
    var onEnable: () -> Void
    var onConnectClaude: () -> Void
    var checking: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch snapshot.availability {
                    case .loading:
                        ForEach(0..<2) { _ in
                            VStack(alignment: .leading, spacing: 10) {
                                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.08)).frame(width: 70, height: 10)
                                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.05)).frame(height: 5)
                                RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.05)).frame(width: 140, height: 8)
                            }.padding(.vertical, 10)
                        }.accessibilityHidden(true)
                    case .available:
                        ForEach(Array(snapshot.providers.enumerated()), id: \.element.id) { index, provider in
                            if index > 0 { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
                            providerSection(provider, now: context.date)
                        }
                    case .disabled:
                        emptyState
                    }
                }.padding(.horizontal, 22).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityLabel(snapshot.availability == .loading ? "Loading usage limits" : "Usage limits")
        }
    }
    private func providerSection(_ provider: ProviderUsage, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: provider.id.symbol)
                    .foregroundStyle(provider.id.color)
                Text(provider.title).fontWeight(.semibold)
                Spacer()
                if let date = provider.updatedAt {
                    HStack(spacing: 3) {
                        if provider.isStale(now: now) { Text("Stale ·") }
                        Text(date, style: .relative)
                        Text("ago")
                    }.font(.system(size: 9)).foregroundStyle(provider.isStale(now: now) ? .orange : .secondary)
                        .help("Updated: \(date.formatted())")
                }
            }.font(.system(size: 12))
                .help(provider.identity.map { "\($0.account) · Limits shared across machines using this account" } ?? (provider.usesClaudeCLI ? "Live limits from Claude Code; account details unavailable" : "Account limits"))
            if provider.windows.isEmpty {
                Text(provider.isLoading ? "Connecting…" : (provider.issue?.message ?? "No limits reported by this provider."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if provider.id == .claude && provider.issue == .permissionRequired {
                Button("Connect Claude", action: onConnectClaude).disabled(checking)
                    .font(.system(size: 11, weight: .medium))
            }
            ForEach(provider.windows) { window in quotaRow(window, stale: provider.isStale(now: now), now: now) }
        }
    }
    private func quotaRow(_ window: UsageWindow, stale: Bool, now: Date) -> some View {
        let uncertain = stale || window.isExpired(now: now)
        let tint: Color = uncertain ? .gray : ((window.remainingPercent ?? 100) <= 10 ? .orange : .green)
        return HStack(spacing: 10) {
            Text(window.title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    if let left = window.remainingPercent { Capsule().fill(tint).frame(width: geometry.size.width * left / 100) }
                }
            }.frame(width: 54, height: 3).accessibilityHidden(true)
            Text(window.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                .monospacedDigit().foregroundStyle(uncertain ? .secondary : .primary).frame(width: 34, alignment: .trailing)
            Text(window.resetLabel(now: now).replacingOccurrences(of: "Resets in ", with: ""))
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).frame(width: 65, alignment: .trailing)
        }.font(.system(size: 11, weight: .medium)).frame(minHeight: 19)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(window.title), \(window.remainingPercent.map { "\(Int($0.rounded())) percent \(uncertain ? "last seen" : "remaining")" } ?? "unavailable"), \(window.resetLabel(now: now))")
            .help(window.resetsAt.map { "Reset: \($0.formatted())" } ?? "Reset time unavailable")
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 23, weight: .light)).foregroundStyle(NotchStyle.accent)
            Text(enabled ? "Your limits, beside your agents" : "Usage is turned off").font(.system(size: 13, weight: .semibold))
            Text("See remaining limits and resets using your existing Codex, Claude Code, and Grok sign-ins.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Enable usage", action: onEnable)

        }.padding(.vertical, 4)
    }
}
