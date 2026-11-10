// The Today page's Shipped section: what reached GitHub that day for the main project, read
// through the GitHub CLI. One plain sentence on top (who merged how much, what went to
// production), then Production, Merged into staging and Pushed, each grouped by person.
// On today it also offers yesterday, and opens on yesterday until something ships today.
import AppKit
import SwiftUI
import BurroCore

struct TodayShippedSection: View {
    @Bindable var store: AppStore
    @State private var pick: Pick?
    @State private var copied = false

    enum Pick: Hashable { case today, yesterday }

    var body: some View {
        let today = store.today, shipped = store.shipped
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today.day) ?? today.day
        let showing: Pick = today.isToday ? (pick ?? automatic(shipped.state(today.day))) : .today
        let day = showing == .yesterday ? yesterday : today.day
        let state = shipped.state(day)
        VStack(alignment: .leading, spacing: 12) {
            header(state: state, today: today, yesterday: yesterday, showing: showing)
            switch state {
            case .loaded(let value): ShippedDayView(day: value, live: today.isToday && showing == .today)
            case .failed(let failure):
                HomeEmptyCard(symbol: "exclamationmark.triangle", title: failure.title, detail: failure.detail) {
                    PillButton(title: "Try again", symbol: "arrow.clockwise") { shipped.refresh(day, force: true) }
                }
            case nil where store.mainProject == nil && store.didScan:
                HomeEmptyCard(symbol: "shippingbox", title: "No main project yet",
                              detail: "Shipped reads the main project's GitHub repository. Pick one on Home.") { EmptyView() }
            case .loading, nil:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading GitHub…").font(.system(size: 13)).foregroundStyle(AppAppearance.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
            }
        }
        // Again once the main project is known (the first scan may still be running).
        .task(id: "\(day.timeIntervalSince1970)|\(store.mainProject?.path ?? "")") { shipped.refresh(day) }
        .onChange(of: today.day) { _, _ in pick = nil }
    }

    /// Today once anything has merged or gone out today; until then, yesterday's recap.
    private func automatic(_ state: ShippedStore.State?) -> Pick {
        if case .loaded(let value) = state, value.merged.isEmpty, value.production.isEmpty { return .yesterday }
        return .today
    }

    private func header(state: ShippedStore.State?, today: TodayStore, yesterday: Date, showing: Pick) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("SHIPPED").font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(AppAppearance.tertiary)
            if case .loaded(let value) = state {
                Button { openOnGitHub(value.repositoryURL) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 10, weight: .medium))
                        Text(value.repository.split(separator: "/").last.map(String.init) ?? value.repository)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.tertiary)
                }
                .buttonStyle(.plain).help("Open \(value.repository) on GitHub")
            }
            Spacer()
            if case .loaded(let value) = state {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ShippedText.render(value), forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                        .padding(.horizontal, 12).frame(height: 28)
                        .overlay(Capsule().strokeBorder(AppAppearance.separator))
                }
                .buttonStyle(.plain).help("Copy this summary as text, for a chat or a standup")
            }
            if today.isToday {
                CapsulePicker(options: [(Pick.today, title("Today", store.shipped.shipped(today.day))),
                                        (Pick.yesterday, title("Yesterday", store.shipped.shipped(yesterday)))],
                              selection: Binding(get: { showing }, set: { pick = $0 }))
            }
        }
        .padding(.horizontal, 2)
    }

    private func title(_ label: String, _ day: ShippedDay?) -> String {
        guard let day else { return label }
        let count = day.merged.count + day.production.count
        return count > 0 ? "\(label) · \(count)" : label
    }
}

/// Opens a GitHub (or deployment) page in the browser; only https links GitHub handed back.
@MainActor private func openOnGitHub(_ url: URL?) {
    guard let url, url.scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}

// MARK: The day

private struct ShippedDayView: View {
    var day: ShippedDay
    var live: Bool

    var body: some View {
        let people = day.contributors
        VStack(alignment: .leading, spacing: 14) {
            summary(people)
            if !day.production.isEmpty {
                ShippedGroup(title: "Production", color: AppAppearance.green, count: day.production.count) {
                    ForEach(Array(day.production.enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Divider().overlay(AppAppearance.separator).padding(.leading, 58) }
                        ReleaseRow(day: day, release: release)
                    }
                }
            }
            let merging = people.filter { !day.merged(by: $0.login).isEmpty }
            if !merging.isEmpty {
                let defaultOnly = day.merged.allSatisfy { $0.base == day.defaultBranch }
                ShippedGroup(title: defaultOnly ? "Merged into \(day.defaultBranch)" : "Merged", color: AppAppearance.blue, count: day.merged.count) {
                    ForEach(Array(merging.enumerated()), id: \.element.id) { index, person in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        MergedBlock(day: day, person: person)
                    }
                }
            }
            let pushing = people.filter { !day.branches(by: $0.login).isEmpty }
            if !pushing.isEmpty {
                ShippedGroup(title: "Pushed", color: .purple, count: day.pushCount) {
                    ForEach(Array(pushing.enumerated()), id: \.element.id) { index, person in
                        if index > 0 { Divider().overlay(AppAppearance.separator) }
                        PushedBlock(day: day, person: person)
                    }
                }
            }
        }
    }

    private func summary(_ people: [ShippedDay.Person]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(day.isEmpty ? (live ? "Nothing on GitHub yet today." : "Nothing reached GitHub that day.") : day.headline)
                .font(.system(size: 15, weight: .medium)).foregroundStyle(AppAppearance.text)
                .fixedSize(horizontal: false, vertical: true)
            if !people.isEmpty {
                // Each person's share, so yours and your teammates' read side by side.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { ForEach(people.prefix(4)) { PersonTally(day: day, person: $0) } }
                    VStack(alignment: .leading, spacing: 8) { ForEach(people.prefix(4)) { PersonTally(day: day, person: $0) } }
                }
            }
            HStack(spacing: 6) {
                Text(live ? "Updated \(day.fetchedAt.formatted(date: .omitted, time: .shortened)) · every 5 minutes while open"
                          : "From GitHub at \(day.fetchedAt.formatted(date: .omitted, time: .shortened))")
                if day.partial { Text("· GitHub's lists were long, so some pushes may be missing").foregroundStyle(AppAppearance.amber) }
            }
            .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AppCardSurface(radius: HomeStyle.cardRadius))
    }
}

private struct PersonTally: View {
    var day: ShippedDay
    var person: ShippedDay.Person
    var body: some View {
        let merged = day.merged(by: person.login).count
        let pushes = day.branches(by: person.login).reduce(0) { $0 + $1.pushes }
        let releases = day.production.filter { $0.actor == person.login }.count
        HStack(spacing: 8) {
            PersonAvatar(person: person, size: 24)
            Text(person.displayName).font(.system(size: 13, weight: .semibold))
            Text([releases > 0 ? "\(releases) to prod" : nil, merged > 0 ? "\(merged) merged" : nil,
                  pushes > 0 ? ShippedDay.count(pushes, "push") : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
        }
    }
}

/// A collapsible titled card, like the chat groups below it.
private struct ShippedGroup<Content: View>: View {
    var title: String
    var color: Color
    var count: Int
    @ViewBuilder var content: () -> Content
    @State private var expanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(AppAppearance.tertiary)
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text("\(count)").font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) { content() }
                    .clipShape(RoundedRectangle(cornerRadius: HomeStyle.cardRadius, style: .continuous))
                    .modifier(SoftSurface(radius: HomeStyle.cardRadius, shadowRadius: 8, y: 2))
            }
        }
    }
}

// MARK: Rows

private struct ReleaseRow: View {
    var day: ShippedDay
    var release: ShippedDay.Release
    @State private var hovering = false
    var body: some View {
        let promotion = release.kind == .promotion ? ShippedDay.promotion(release.title) : nil
        Button { openOnGitHub(release.url) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30).background(tint.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(promotion?.text ?? release.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(AppAppearance.text)
                    Text(detail(promotion)).font(.system(size: 12)).lineLimit(1).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 8)
                if let status = release.status { StatusPill(status: status) }
                Text(release.at, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary).frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help([release.title, release.target].compactMap { $0 }.joined(separator: "\n"))
    }

    private func detail(_ promotion: (text: String, from: String, to: String)?) -> String {
        var parts: [String] = []
        if let promotion {
            parts.append("Promoted \(promotion.from) → \(promotion.to)")
            parts.append(release.detail.components(separatedBy: " into ").first ?? release.detail)
        } else {
            parts.append(release.detail)
        }
        if let actor = release.actor { parts.append(day.person(actor).displayName) }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        switch release.kind {
        case .promotion: "airplane.departure"
        case .push: "arrow.up.to.line"
        case .workflow: "gearshape.2"
        case .deployment: "icloud.and.arrow.up"
        }
    }
    private var tint: Color { release.status == .failed ? Color(red: 0.92, green: 0.36, blue: 0.36) : AppAppearance.green }
}

private struct StatusPill: View {
    var status: ShippedDay.Release.Status
    var body: some View {
        Text(ShippedText.title(status)).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }
    private var color: Color {
        switch status {
        case .live, .succeeded: AppAppearance.green
        case .running: AppAppearance.blue
        case .waiting: AppAppearance.amber
        case .failed: Color(red: 0.92, green: 0.36, blue: 0.36)
        case .cancelled: AppAppearance.tertiary
        }
    }
}

/// One person's merged pull requests: the latest few, the rest a click away.
private struct MergedBlock: View {
    var day: ShippedDay
    var person: ShippedDay.Person
    @State private var all = false
    var body: some View {
        let pulls = day.merged(by: person.login)
        let shown = all ? pulls : Array(pulls.prefix(6))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PersonAvatar(person: person, size: 26)
                Text(person.displayName).font(.system(size: 13, weight: .semibold))
                Text(ShippedDay.count(pulls.count, "pull request")).font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                Spacer()
                let added = pulls.reduce(0) { $0 + $1.additions }, removed = pulls.reduce(0) { $0 + $1.deletions }
                HStack(spacing: 5) {
                    Text("+" + HomeFormat.tokens(Double(added))).foregroundStyle(AppAppearance.green.opacity(0.8))
                    Text("−" + HomeFormat.tokens(Double(removed))).foregroundStyle(Color(red: 0.92, green: 0.36, blue: 0.36).opacity(0.8))
                }
                .font(.system(size: 11.5)).monospacedDigit()
                .help("\(added.formatted()) lines added, \(removed.formatted()) removed")
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ForEach(shown) { pull in PullRow(day: day, pull: pull) }
            MoreButton(hidden: pulls.count - shown.count, all: $all, noun: "pull request")
        }
        .padding(.bottom, 8)
    }
}

private struct PullRow: View {
    var day: ShippedDay
    var pull: ShippedDay.PullRequest
    @State private var hovering = false
    var body: some View {
        let parts = ShippedDay.area(of: pull.title)
        Button { openOnGitHub(pull.url) } label: {
            HStack(spacing: 8) {
                if let area = parts.area { AreaTag(text: area) }
                Text(parts.text).font(.system(size: 13)).lineLimit(1).foregroundStyle(AppAppearance.text)
                if pull.base != day.defaultBranch {
                    Text("→ \(pull.base)").font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary)
                }
                Spacer(minLength: 8)
                Text(verbatim: "#\(pull.number)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                Text(pull.mergedAt, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary).frame(width: 44, alignment: .trailing)
            }
            .padding(.leading, 52).padding(.trailing, 16).padding(.vertical, 6)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help("\(pull.title)\n+\(pull.additions) −\(pull.deletions) · \(pull.head) → \(pull.base)")
    }
}

/// One person's pushes: work still in flight first (open pull requests, branches without one,
/// straight pushes to staging), then branches whose pull request already merged, folded away.
private struct PushedBlock: View {
    var day: ShippedDay
    var person: ShippedDay.Person
    @State private var all = false
    @State private var showMerged = false
    var body: some View {
        let branches = day.branches(by: person.login)
        let landed = branches.filter { $0.pullRequest?.state == "MERGED" }
        let flying = branches.filter { $0.pullRequest?.state != "MERGED" }
        let shown = all ? flying : Array(flying.prefix(5))
        let pushes = branches.reduce(0) { $0 + $1.pushes }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                PersonAvatar(person: person, size: 26)
                Text(person.displayName).font(.system(size: 13, weight: .semibold))
                Text("\(ShippedDay.count(pushes, "push")) to \(ShippedDay.count(branches.count, "branch"))")
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ForEach(shown) { branch in BranchRow(day: day, branch: branch) }
            MoreButton(hidden: flying.count - shown.count, all: $all, noun: "branch")
            if !landed.isEmpty {
                Button { withAnimation(.easeOut(duration: 0.15)) { showMerged.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(showMerged ? 90 : 0))
                        Text("\(ShippedDay.count(landed.count, "branch")) merged, listed above · \(ShippedDay.count(landed.reduce(0) { $0 + $1.pushes }, "push"))")
                    }
                    .font(.system(size: 12)).foregroundStyle(AppAppearance.tertiary)
                    .padding(.leading, 52).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showMerged { ForEach(landed) { branch in BranchRow(day: day, branch: branch) } }
            }
        }
        .padding(.bottom, 8)
    }
}

private struct BranchRow: View {
    var day: ShippedDay
    var branch: ShippedDay.Branch
    @State private var hovering = false
    var body: some View {
        let straight = branch.name == day.defaultBranch
        Button { openOnGitHub(link) } label: {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(AppAppearance.tertiary, lineWidth: branch.pullRequest == nil && !straight ? 1 : 0))
                if let pull = branch.pullRequest {
                    let parts = ShippedDay.area(of: pull.title)
                    if let area = parts.area { AreaTag(text: area) }
                    Text(parts.text).font(.system(size: 13)).lineLimit(1).foregroundStyle(AppAppearance.text)
                } else {
                    Text(branch.name).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(straight ? AppAppearance.amber : AppAppearance.text)
                }
                if straight { Tag(text: "straight to \(day.defaultBranch)", color: AppAppearance.amber) }
                if branch.forced > 0 { Tag(text: "force-pushed", color: AppAppearance.tertiary) }
                Spacer(minLength: 8)
                if let pull = branch.pullRequest {
                    Text(verbatim: "#\(pull.number)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                }
                Text(ShippedDay.count(branch.pushes, "push")).font(.system(size: 12)).monospacedDigit().foregroundStyle(AppAppearance.secondary)
                Text(branch.lastAt, format: .dateTime.hour().minute()).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AppAppearance.tertiary).frame(width: 44, alignment: .trailing)
            }
            .padding(.leading, 52).padding(.trailing, 16).padding(.vertical, 6)
            .background(hovering ? AppAppearance.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .help(help)
    }

    private var dot: Color {
        switch branch.pullRequest?.state {
        case "OPEN": AppAppearance.green
        case "MERGED": .purple
        default: branch.name == day.defaultBranch ? AppAppearance.amber : .clear
        }
    }
    private var link: URL? {
        if let url = branch.pullRequest?.url { return url }
        let path = branch.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch.name
        return URL(string: "https://github.com/\(day.repository)/commits/\(path)")
    }
    private var help: String {
        var lines = [branch.name]
        if let pull = branch.pullRequest { lines.insert("\(pull.title) (#\(pull.number), \(pull.state.lowercased()))", at: 0) }
        else if branch.name != day.defaultBranch { lines.append("No pull request yet") }
        if branch.created { lines.append("New branch today") }
        return lines.joined(separator: "\n")
    }
}

private struct MoreButton: View {
    var hidden: Int
    @Binding var all: Bool
    var noun: String
    var body: some View {
        if hidden > 0 || all {
            Button { withAnimation(.easeOut(duration: 0.15)) { all.toggle() } } label: {
                Text(all ? "Show fewer" : "Show \(hidden) more")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(AppAppearance.blue)
                    .padding(.leading, 52).padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AreaTag: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize()
            .foregroundStyle(AppAppearance.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(AppAppearance.raised, in: Capsule())
    }
}

private struct Tag: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// A GitHub avatar, or the person's initial while it loads (or without one).
struct PersonAvatar: View {
    var person: ShippedDay.Person
    var size: CGFloat
    var body: some View {
        let initial = Circle().fill(HomeStyle.tint(for: person.login).opacity(0.85))
            .overlay(Text(String(person.displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded)).foregroundStyle(.white))
        Group {
            if let url = person.avatar {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { initial }
                }
            } else { initial }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().strokeBorder(AppAppearance.separator))
        .help(person.isYou ? "You (\(person.login))" : [person.name, person.login].compactMap { $0 }.joined(separator: " · "))
    }
}
