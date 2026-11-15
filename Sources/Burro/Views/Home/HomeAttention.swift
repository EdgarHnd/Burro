// Home's attention strip, directly under the greeting: what needs you, then what is ready to read.
// Chats that need you are amber rows (avatar, title, machine · folder) that open the chat; up to
// five show, with a button to see the rest in Chats. Chats with a result to read are one quieter
// line that opens Chats. With nothing waiting it says "Nothing needs you" in quiet text.
import SwiftUI
import BurroCore

struct HomeAttention: View {
    var store: AppStore
    var summary: HomeSummary
    /// Rows shown before "Show all N in Chats".
    static let cap = 5

    var body: some View {
        let needsYou = summary.needsYou
        let unread = summary.unread
        if needsYou.isEmpty && unread.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                Text(store.didCheckAgents ? "Nothing needs you" : "Checking on your agents…")
            }
            .font(.system(size: 13)).foregroundStyle(AppAppearance.tertiary)
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if !needsYou.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(needsYou.prefix(Self.cap)) { session in
                            HomeAttentionRow(session: session, place: place(session)) { store.showChat(session) }
                        }
                        if needsYou.count > Self.cap {
                            Button("Show all \(needsYou.count) in Chats") { store.page = .remote }
                                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                                .padding(.horizontal, 10).padding(.top, 6)
                                .help("Open Chats")
                        }
                    }
                    .padding(8)
                }
                if !needsYou.isEmpty && !unread.isEmpty {
                    Rectangle().fill(AppAppearance.separator).frame(height: 1)
                }
                if !unread.isEmpty {
                    Button { store.page = .remote } label: {
                        HStack(spacing: 8) {
                            Circle().fill(AppAppearance.blue).frame(width: 6, height: 6)
                            Text("\(unread.count) ready to read").font(.system(size: 13)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                            Spacer(minLength: 8)
                            Text("Open Chats").font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 11).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open Chats to read \(unread.count == 1 ? "this result" : "these results")")
                    .accessibilityLabel("\(unread.count) ready to read. Open Chats")
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
        }
    }

    /// "machine · folder": the remote's name, or this Mac's, then the chat's folder.
    private func place(_ session: AgentSession) -> String {
        let folder = URL(fileURLWithPath: store.workspacePath(for: session)).lastPathComponent
        let machine = session.remote?.hostName ?? summary.machines.first { $0.connection == .local }?.name ?? "This Mac"
        return [machine, folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct HomeAttentionRow: View {
    var session: AgentSession
    var place: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(AppAppearance.amber)
                    .frame(width: 14)
                AgentAvatar(session: session, active: false, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).foregroundStyle(AppAppearance.text)
                    Text(place).font(.system(size: 11)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("Open")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? AppAppearance.text : AppAppearance.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hovering ? AppAppearance.amber.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open this chat")
        .accessibilityLabel("\(session.title), needs you, \(place). Open")
    }
}
