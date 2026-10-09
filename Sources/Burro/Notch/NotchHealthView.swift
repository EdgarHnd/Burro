// Machine-scoped monitoring details distinguish reachability from bounded historical coverage.
import SwiftUI

struct NotchNotice: Identifiable {
    var id: String
    var source: String
    var summary: String
    var messages: [String]
    var checkedAt: Date?
    var connectionIssue = false
}
struct NotchHealthView: View {
    var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Monitoring").font(.system(size: 13, weight: .semibold))
                if store.notchNotices.isEmpty && store.agentActivity.unverifiedSessions.isEmpty {
                    Text("No monitoring notices.").foregroundStyle(.secondary)
                }
                ForEach(store.notchNotices) { notice in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(notice.summary).fontWeight(.medium)
                        ForEach(notice.messages, id: \.self) { Text($0).foregroundStyle(.secondary) }
                        if let checked = notice.checkedAt {
                            HStack(spacing: 4) { Text("Last successful check"); Text(checked, style: .relative) }
                                .foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10).modifier(AppCardSurface(translucent: true))
                }
                if !store.agentActivity.unverifiedSessions.isEmpty {
                    Text("Unverified chats").fontWeight(.medium)
                    Text("These chats stay protected. Burro cannot confirm their current activity.")
                        .foregroundStyle(.secondary)
                    ForEach(store.agentActivity.unverifiedSessions) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(session.title).fontWeight(.medium).lineLimit(2)
                            Text("\(session.provider.rawValue) · \(session.remote?.hostName ?? "This Mac")").foregroundStyle(.secondary)
                            Text(session.evidence).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).modifier(AppCardSurface(translucent: true))
                    }
                }
                Button("Check again") { Task { await store.refreshAgents(); await store.refreshRemotes() } }
                    .disabled(store.checkingAgents || store.checkingRemotes)
            }.font(.system(size: 11)).padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(AppButtonStyle()).controlSize(.mini)
    }
}
