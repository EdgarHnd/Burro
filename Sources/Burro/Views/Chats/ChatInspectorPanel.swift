// The chat details panel's layout, values only (`ChatInspector` gathers them): FOLDER (the
// worktree's branch, "4 uncommitted · 2 unpushed", the path, Open worktree and Review cleanup…),
// CHANGES (each file the branch changed with +/− lines, largest first, "4 files" in the header;
// a remote chat says where it runs), CONTEXT ("124K of 200K" over a meter when the model's window
// is known, otherwise "500K tokens", in any language), COST SO FAR ("$3.84" at API list prices, or "—") beside STARTED,
// and background tasks still running.
import SwiftUI
import BurroCore

struct ChatInspectorValues {
    enum Changes: Equatable {
        case loading, notGit, remote(String), files(ChatChangeList)
    }
    struct Folder {
        var name: String
        var path: String
        var branch: String?
        var pending: String?
        /// A scanned worktree: Open worktree applies; Review cleanup unless it's the main checkout.
        var worktree: Bool
        var primary: Bool
    }
    var folder: Folder
    var changes: Changes
    var contextTokens: Int?
    var contextWindow: Int?
    var cost: Double?
    var costKnown: Bool
    var started: Date?
    var tasks: [ChatMessage] = []
}

struct ChatInspectorPanel: View {
    var values: ChatInspectorValues
    var cleaning = false
    var openWorktree: () -> Void = {}
    var reviewCleanup: () -> Void = {}
    var now: Date? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                folder
                rule
                changes
                if let tokens = values.contextTokens, tokens > 0 {
                    rule
                    context(tokens: tokens, window: values.contextWindow)
                }
                rule
                HStack(alignment: .top, spacing: 10) {
                    fact("Cost so far") {
                        Text(values.costKnown ? ChatCost.label(values.cost) : "…")
                            .help("Estimated from this chat's token counts at API list prices, not a bill. “—” when Burro can't price it (another machine, an unknown model, or no usage recorded).")
                    }
                    fact("Started") {
                        if let started = values.started { Text(Self.startedText(started, now: now ?? Date())) } else { Text("—") }
                    }
                }
                if !values.tasks.isEmpty {
                    rule
                    tasks
                }
            }
            .padding(16)
        }
        .frame(width: 280)
        .background(AppAppearance.background)
        .overlay(alignment: .leading) { Rectangle().fill(AppAppearance.separator).frame(width: 1) }
    }

    private var rule: some View { Rectangle().fill(AppAppearance.separator).frame(height: 1) }

    private func header(_ title: String, trailing: String? = nil) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            Spacer(minLength: 6)
            if let trailing { Text(trailing).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary) }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var folder: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Folder")
            HStack(spacing: 6) {
                Image(systemName: values.folder.branch == nil ? "folder" : "arrow.triangle.branch").font(.system(size: 11))
                    .foregroundStyle(AppAppearance.secondary).accessibilityHidden(true)
                Text(values.folder.branch ?? values.folder.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            if let pending = values.folder.pending {
                Text(pending).font(.system(size: 12.5)).foregroundStyle(AppAppearance.secondary)
            }
            Text(Self.abbreviated(values.folder.path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                .lineLimit(1).truncationMode(.middle).help(values.folder.path).textSelection(.enabled)
            if values.folder.worktree {
                HStack(spacing: 6) {
                    Button(action: openWorktree) { ChatButtonLabel(title: "Open worktree") }.buttonStyle(.plain)
                        .help("Show this worktree on Burro's Worktrees page")
                    if !values.folder.primary {
                        Button(action: reviewCleanup) { ChatButtonLabel(title: "Review cleanup…", enabled: !cleaning) }.buttonStyle(.plain)
                            .disabled(cleaning).help("Check whether this worktree is safe to clean up, with the usual confirmation")
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder private var changes: some View {
        switch values.changes {
        case .files(let list) where !list.files.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                header("Changes", trailing: "\(list.files.count) file\(list.files.count == 1 ? "" : "s")")
                ForEach(list.files.prefix(12)) { file in
                    HStack(spacing: 8) {
                        Text(file.name).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading).help(file.path)
                        if let added = file.added, let removed = file.removed {
                            Text("+\(added)").foregroundStyle(AppAppearance.green)
                            Text("−\(removed)").foregroundStyle(Self.red)
                        } else {
                            Text("binary").foregroundStyle(AppAppearance.tertiary)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
                if list.files.count > 12 {
                    Text("and \(list.files.count - 12) more · +\(list.added) −\(list.removed) in all")
                        .font(.system(size: 11.5)).foregroundStyle(AppAppearance.tertiary)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                header("Changes")
                Text(changesNote).font(.system(size: 12.5)).foregroundStyle(AppAppearance.tertiary)
            }
        }
    }

    private var changesNote: String {
        switch values.changes {
        case .loading: "Reading…"
        case .notGit: "Not a Git folder"
        case .remote(let machine): "Runs on \(machine); changes are listed for chats on this Mac"
        case .files: "No changes since the branch left its base"
        }
    }

    private func context(tokens: Int, window: Int?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let window, window > 0 {
                let share = min(1, Double(tokens) / Double(window))
                header("Context", trailing: "\(TokenCount.compact(Double(tokens))) of \(TokenCount.compact(Double(window)))")
                GeometryReader { geometry in
                    Capsule().fill(AppAppearance.raised)
                        .overlay(alignment: .leading) {
                            Capsule().fill(share > 0.8 ? AppAppearance.amber : AppAppearance.secondary).frame(width: max(4, geometry.size.width * share))
                        }
                }
                .frame(height: 5)
                .accessibilityElement().accessibilityLabel("Context \(Int((share * 100).rounded())) percent full")
            } else {
                header("Context", trailing: "\(TokenCount.compact(Double(tokens))) tokens")
            }
        }
    }

    private func fact<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header(title)
            value().font(.system(size: 17, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Background tasks", trailing: "\(values.tasks.count)")
            ForEach(values.tasks) { task in
                HStack(spacing: 8) {
                    Image(systemName: "person.2").font(.system(size: 10.5)).foregroundStyle(AppAppearance.tertiary).accessibilityHidden(true)
                    Text(task.note ?? task.text).font(.system(size: 12.5)).lineLimit(2)
                    Spacer(minLength: 4)
                    if let at = task.at {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(ChatInspector.duration(context.date.timeIntervalSince(at))).font(.system(size: 11.5)).monospacedDigit()
                                .foregroundStyle(AppAppearance.tertiary)
                        }
                    }
                }
            }
        }
    }

    static let red = Color(red: 0.88, green: 0.42, blue: 0.48)

    /// "21:02" today, else "Yesterday", "Mon" or "3 Nov".
    static func startedText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        guard calendar.isDate(date, inSameDayAs: now) else { return ChatRowTime.label(date, now: now, calendar: calendar) }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The path with the home folder as ~.
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}
