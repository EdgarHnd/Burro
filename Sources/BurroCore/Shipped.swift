// What shipped on GitHub in one day, for one repository: pull requests merged into its default
// branch (staging), production releases (promotions into main, production workflow runs and
// Production deployments) and every push, per person. Read-only, through the GitHub CLI's own
// sign-in; nothing is written to GitHub or kept on disk (the written summary in
// ShippedSummary.swift keeps its own small cache).
import Foundation

public struct ShippedDay: Sendable, Equatable {
    public struct Person: Sendable, Equatable, Identifiable {
        public var login: String
        public var name: String?
        public var avatar: URL?
        public var isYou: Bool
        public var isBot: Bool
        public var id: String { login }
        public init(login: String, name: String?, avatar: URL?, isYou: Bool, isBot: Bool) {
            self.login = login; self.name = name; self.avatar = avatar; self.isYou = isYou; self.isBot = isBot
        }
        /// "You", a first name, or the login.
        public var displayName: String {
            if isYou { return "You" }
            if let first = name?.split(separator: " ").first, !first.isEmpty { return String(first) }
            return login
        }
    }

    public struct PullRequest: Sendable, Equatable, Identifiable {
        public var number: Int
        public var title: String
        public var url: URL?
        public var author: String
        public var mergedAt: Date
        public var base: String
        public var head: String
        public var additions: Int
        public var deletions: Int
        public var mergeCommit: String?
        public var id: Int { number }
    }

    public struct Release: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case promotion, push, workflow, deployment }
        public enum Status: String, Sendable { case live, succeeded, running, waiting, failed, cancelled }
        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String
        public var actor: String?
        public var at: Date
        public var status: Status?
        public var url: URL?
        /// Where it went live, when a deployment says (environments and their URL).
        public var target: String?
    }

    /// One person's pushes to one branch that day.
    public struct Branch: Sendable, Equatable, Identifiable {
        public struct Linked: Sendable, Equatable {
            public var number: Int
            public var title: String
            public var state: String
            public var url: URL?
        }
        public var actor: String
        public var name: String
        public var pushes: Int
        public var forced: Int
        public var created: Bool
        public var lastAt: Date
        public var pullRequest: Linked?
        public var id: String { actor + " " + name }
    }

    public var day: Date
    public var repository: String
    public var defaultBranch: String
    public var you: String?
    public var people: [String: Person]
    public var production: [Release]
    /// Every pull request merged that day, into any branch except a production one.
    public var merged: [PullRequest]
    public var branches: [Branch]
    /// Some pushes or merges may be missing (GitHub's lists were longer than Burro reads).
    public var partial: Bool
    public var fetchedAt: Date

    public var repositoryURL: URL? { URL(string: "https://github.com/\(repository)") }
    public var pushCount: Int { branches.reduce(0) { $0 + $1.pushes } }
    public var isEmpty: Bool { production.isEmpty && merged.isEmpty && branches.isEmpty }

    public func person(_ login: String) -> Person {
        people[login] ?? Person(login: login, name: nil, avatar: nil, isYou: login == you, isBot: Self.isBot(login))
    }
    public func merged(by login: String) -> [PullRequest] { merged.filter { $0.author == login }.sorted { $0.mergedAt > $1.mergedAt } }
    /// Straight pushes to the default branch first, then the latest.
    public func branches(by login: String) -> [Branch] {
        branches.filter { $0.actor == login }.sorted {
            ($0.name == defaultBranch) != ($1.name == defaultBranch) ? $0.name == defaultBranch : $0.lastAt > $1.lastAt
        }
    }

    /// Everyone who merged or pushed: you first, then by how much.
    public var contributors: [Person] {
        var weight: [String: Int] = [:]
        for pull in merged { weight[pull.author, default: 0] += 10 }
        for branch in branches { weight[branch.actor, default: 0] += branch.pushes }
        for release in production { if let actor = release.actor { weight[actor, default: 0] += 10 } }
        let authors = Set(merged.map(\.author))
        return weight.keys.map(person).filter { !$0.isBot || authors.contains($0.login) }.sorted {
            if $0.isYou != $1.isYou { return $0.isYou }
            let a = weight[$0.login] ?? 0, b = weight[$1.login] ?? 0
            return a != b ? a > b : $0.login.lowercased() < $1.login.lowercased()
        }
    }

    /// One or two plain sentences: who merged how much into staging, and what reached production.
    public var headline: String {
        let counts = contributors.compactMap { person -> (String, Int)? in
            let count = merged.filter { $0.author == person.login && $0.base == defaultBranch }.count
            return count > 0 ? (person.displayName, count) : nil
        }
        var text: String
        if let first = counts.first {
            text = "\(first.0) merged \(Self.count(first.1, "pull request")) into \(defaultBranch)"
            let rest = counts.dropFirst()
            if rest.count == 1, let only = rest.first {
                text += " and \(only.0) merged \(only.1)"
            } else if rest.count > 1 {
                let items = rest.map { "\($0.0) \($0.1)" }
                text += ", " + items.dropLast().joined(separator: ", ") + " and " + (items.last ?? "")
            }
            text += "."
        } else {
            text = "No pull requests merged into \(defaultBranch)."
        }
        let failed = production.filter { $0.status == .failed }.count
        let shipped = production.filter { $0.status != .failed && $0.status != .cancelled }.count
        switch shipped {
        case 0 where production.isEmpty: text += " Nothing went to production."
        case 0: break
        case 1: text += " Shipped to production once."
        case 2: text += " Shipped to production twice."
        default: text += " Shipped to production \(shipped) times."
        }
        if failed > 0 { text += failed == 1 ? " One production run failed." : " \(failed) production runs failed." }
        return text
    }

    /// A promotion's title without its "Promote staging to main: " lead, and the branches it names.
    public static func promotion(_ title: String) -> (text: String, from: String, to: String)? {
        guard let match = title.firstMatch(of: /^[Pp]romote ([\w.\/-]+) (?:to|into|→) ([\w.\/-]+)(?::\s*|\s+[-–—]\s+)(.+)$/) else { return nil }
        return (capitalizedFirst(String(match.3)), String(match.1), String(match.2))
    }

    /// The area a title names before a colon ("Store: …", "fix(insights): …"), and the rest.
    public static func area(of title: String) -> (area: String?, text: String) {
        guard let colon = title.range(of: ": ") else { return (nil, title) }
        let prefix = String(title[..<colon.lowerBound])
        let rest = title[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !prefix.isEmpty, prefix.count <= 28 else { return (nil, title) }
        if let match = prefix.wholeMatch(of: /([a-z]+)(?:\(([^)]+)\))?!?/) {
            let kind = String(match.1), scope = match.2.map(String.init)
            switch kind {
            case "docs": return ("Docs", capitalizedFirst(rest))
            case "ci", "build": return ("CI", capitalizedFirst(rest))
            case "test", "tests": return ("Tests", capitalizedFirst(rest))
            case "feat", "fix", "chore", "refactor", "perf", "style", "revert":
                return (scope.map(capitalizedFirst), capitalizedFirst(rest))
            default: break
            }
        }
        guard prefix.split(separator: " ").count <= 3, prefix.first?.isLetter == true else { return (nil, title) }
        return (prefix, capitalizedFirst(rest))
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    public static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : (noun.hasSuffix("sh") || noun.hasSuffix("ch") ? "es" : "s"))"
    }
    static func isBot(_ login: String) -> Bool { login.hasSuffix("[bot]") }

    /// Branches that, besides the default one, mean production.
    static let productionBranches: Set<String> = ["main", "master", "production", "prod", "release", "live"]

    static func isProductionWorkflow(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("production") || lower.hasPrefix("prod ") || lower.hasPrefix("prod:") || lower.hasPrefix("deploy to prod")
    }
}

// MARK: GitHub's answers

/// The parts of GitHub's GraphQL, activity and Actions answers Burro reads. Every field is optional:
/// a missing one drops that item rather than the day.
struct ShippedGraph: Decodable, Sendable {
    struct Author: Decodable, Sendable {
        let typename: String?
        let login: String?
        let name: String?
        let avatarUrl: String?
        enum CodingKeys: String, CodingKey { case typename = "__typename", login, name, avatarUrl }
    }
    struct Commit: Decodable, Sendable { let oid: String? }
    struct Pull: Decodable, Sendable {
        let number: Int?
        let title: String?
        let url: String?
        let state: String?
        let mergedAt: String?
        let baseRefName: String?
        let headRefName: String?
        let additions: Int?
        let deletions: Int?
        let mergeCommit: Commit?
        let author: Author?
    }
    struct PageInfo: Decodable, Sendable { let hasNextPage: Bool?; let endCursor: String? }
    struct Search: Decodable, Sendable { let issueCount: Int?; let pageInfo: PageInfo?; let nodes: [Pull]? }
    struct Named: Decodable, Sendable { let name: String? }
    struct Nodes<Node: Decodable & Sendable>: Decodable, Sendable { var nodes: [Node]?; var pageInfo: PageInfo? = nil }
    struct DeploymentStatus: Decodable, Sendable { let state: String?; let environmentUrl: String?; let logUrl: String? }
    struct Deployment: Decodable, Sendable {
        let createdAt: String?
        let commitOid: String?
        let environment: String?
        let state: String?
        let latestStatus: DeploymentStatus?
    }
    struct Repository: Decodable, Sendable {
        let defaultBranchRef: Named?
        let environments: Nodes<Named>?
        let deployments: Nodes<Deployment>?
    }
    struct Viewer: Decodable, Sendable { let login: String? }
    struct Payload: Decodable, Sendable {
        let viewer: Viewer?
        let repository: Repository?
        let merged: Search?
        let touched: Search?
    }
    struct Problem: Decodable, Sendable { let message: String? }
    let data: Payload?
    let errors: [Problem]?
}

struct ShippedActivity: Decodable, Sendable {
    struct Actor: Decodable, Sendable { let login: String?; let avatar_url: String?; let type: String? }
    let activity_type: String?
    let actor: Actor?
    let ref: String?
    let before: String?
    let after: String?
    let timestamp: String?
}

struct ShippedRuns: Decodable, Sendable {
    struct Actor: Decodable, Sendable { let login: String?; let avatar_url: String? }
    struct Run: Decodable, Sendable {
        let id: Int?
        let name: String?
        let display_title: String?
        let html_url: String?
        let status: String?
        let conclusion: String?
        let created_at: String?
        let actor: Actor?
        let triggering_actor: Actor?
    }
    let workflow_runs: [Run]?
}

// MARK: Building the day

extension ShippedDay {
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Puts GitHub's answers for one day together. `graph` holds the merged-PR search pages (the first
    /// also carries the viewer, repository and recently touched PRs), `deployments` the Production
    /// deployments, `activity` the repository activity (any days; only this one is kept).
    static func build(day start: Date, end: Date, repository: String, graph: [ShippedGraph], deployments: ShippedGraph?,
                      activity: [ShippedActivity], runs: ShippedRuns?, partial: Bool, now: Date) -> ShippedDay {
        let first = graph.first?.data
        let you = first?.viewer?.login
        let defaultBranch = first?.repository?.defaultBranchRef?.name ?? "main"
        let production = productionBranches.subtracting([defaultBranch])
        let inDay = { (date: Date) in date >= start && date < end }
        var people: [String: Person] = [:]
        func meet(_ login: String?, name: String? = nil, avatar: String? = nil, bot: Bool = false) {
            guard let login, !login.isEmpty else { return }
            var person = people[login] ?? Person(login: login, name: nil, avatar: nil, isYou: login == you, isBot: bot || isBot(login))
            if person.name == nil, let name, !name.isEmpty, name != login { person.name = name }
            if person.avatar == nil { person.avatar = webURL(avatar) }
            person.isBot = person.isBot || bot
            people[login] = person
        }

        // Merged pull requests, once each.
        var seen = Set<Int>()
        var pulls: [PullRequest] = []
        for page in graph {
            for node in page.data?.merged?.nodes ?? [] {
                guard let number = node.number, let title = node.title, let mergedAt = date(node.mergedAt), inDay(mergedAt),
                      let author = node.author?.login, seen.insert(number).inserted else { continue }
                meet(author, name: node.author?.name, avatar: node.author?.avatarUrl, bot: node.author?.typename == "Bot")
                pulls.append(PullRequest(number: number, title: title, url: webURL(node.url), author: author, mergedAt: mergedAt,
                                         base: node.baseRefName ?? defaultBranch, head: node.headRefName ?? "",
                                         additions: max(0, node.additions ?? 0), deletions: max(0, node.deletions ?? 0),
                                         mergeCommit: node.mergeCommit?.oid))
            }
        }

        // Production deployments by commit.
        var deploys: [String: [ShippedGraph.Deployment]] = [:]
        var dayDeploys: [ShippedGraph.Deployment] = []
        for deployment in deployments?.data?.repository?.deployments?.nodes ?? [] {
            guard let commit = deployment.commitOid else { continue }
            deploys[commit, default: []].append(deployment)
            if let created = date(deployment.createdAt), inDay(created) { dayDeploys.append(deployment) }
        }
        var matched = Set<String>()
        func deployment(for commit: String?) -> (status: Release.Status?, target: String?) {
            guard let commit, let list = deploys[commit], !list.isEmpty else { return (nil, nil) }
            matched.insert(commit)
            let statuses = list.map { deploymentStatus($0) }
            let status: Release.Status? = statuses.contains(.failed) ? .failed
                : statuses.contains(.running) ? .running : statuses.contains(.waiting) ? .waiting
                : statuses.contains(.live) ? .live : nil
            let environments = Array(Set(list.compactMap(\.environment))).sorted()
            let link = list.compactMap { $0.latestStatus?.environmentUrl }.first
            return (status, ([environments.joined(separator: ", ")] + [link].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: "\n"))
        }

        var releases: [Release] = []
        for pull in pulls where production.contains(pull.base) {
            let live = deployment(for: pull.mergeCommit)
            releases.append(Release(id: "pr-\(pull.number)", kind: .promotion, title: pull.title, detail: "#\(pull.number) into \(pull.base)",
                                    actor: pull.author, at: pull.mergedAt, status: live.status, url: pull.url, target: live.target))
        }

        // Pushes: production branches become releases, the rest group by person and branch.
        var groups: [String: Branch] = [:]
        for item in activity {
            guard let kind = item.activity_type, ["push", "force_push", "branch_creation"].contains(kind),
                  let login = item.actor?.login, let ref = item.ref, ref.hasPrefix("refs/heads/"),
                  let at = date(item.timestamp), inDay(at) else { continue }
            let bot = item.actor?.type == "Bot" || isBot(login)
            guard !bot else { continue }
            meet(login, avatar: item.actor?.avatar_url)
            let branch = String(ref.dropFirst("refs/heads/".count))
            if production.contains(branch), kind != "branch_creation" {
                let live = deployment(for: item.after)
                let sha = item.after.map { String($0.prefix(7)) } ?? ""
                releases.append(Release(id: "push-\(item.after ?? UUID().uuidString)", kind: .push,
                                        title: kind == "force_push" ? "Force-pushed to \(branch)" : "Pushed straight to \(branch)",
                                        detail: sha, actor: login, at: at, status: live.status,
                                        url: item.after.flatMap { URL(string: "https://github.com/\(repository)/commit/\($0)") }, target: live.target))
                continue
            }
            let key = login + " " + branch
            var group = groups[key] ?? Branch(actor: login, name: branch, pushes: 0, forced: 0, created: false, lastAt: at, pullRequest: nil)
            group.pushes += 1
            if kind == "force_push" { group.forced += 1 }
            if kind == "branch_creation" { group.created = true }
            group.lastAt = max(group.lastAt, at)
            groups[key] = group
        }

        // Name each branch by its pull request: an open one, else one merged after these pushes (a branch
        // name reused after an old merge is new work, not that pull request). Closed ones don't count.
        var open: [String: (Int, Branch.Linked)] = [:]
        var mergedHeads: [String: [(Date, Int, Branch.Linked)]] = [:]
        let candidates = (first?.touched?.nodes ?? []) + graph.flatMap { $0.data?.merged?.nodes ?? [] }
        for node in candidates {
            guard let head = node.headRefName, let number = node.number, let title = node.title else { continue }
            let mergedAt = date(node.mergedAt)
            let state = node.state ?? (mergedAt == nil ? "OPEN" : "MERGED")
            let item = Branch.Linked(number: number, title: title, state: state, url: webURL(node.url))
            if state == "OPEN" {
                if (open[head]?.0 ?? 0) < number { open[head] = (number, item) }
            } else if state == "MERGED", let mergedAt {
                mergedHeads[head, default: []].append((mergedAt, number, item))
            }
        }
        let branches = groups.values.map { group -> Branch in
            var group = group
            guard group.name != defaultBranch else { return group }
            if let item = open[group.name]?.1 {
                group.pullRequest = item
            } else if let match = mergedHeads[group.name]?.filter({ $0.0.addingTimeInterval(60) >= group.lastAt }).min(by: { $0.0 < $1.0 }) {
                group.pullRequest = match.2
            }
            return group
        }.sorted { $0.lastAt > $1.lastAt }

        // Production workflow runs.
        for run in runs?.workflow_runs ?? [] {
            guard let name = run.name, isProductionWorkflow(name), let created = date(run.created_at), inDay(created) else { continue }
            let actor = run.triggering_actor?.login ?? run.actor?.login
            meet(actor, avatar: run.triggering_actor?.avatar_url ?? run.actor?.avatar_url)
            let title = run.display_title.flatMap { $0 == name || $0.isEmpty ? nil : $0 } ?? name
            releases.append(Release(id: "run-\(run.id ?? 0)", kind: .workflow, title: title, detail: title == name ? "Workflow" : name,
                                    actor: actor, at: created, status: runStatus(run.status, run.conclusion), url: webURL(run.html_url), target: nil))
        }

        // Production deployments nothing above accounts for (a redeploy, another project).
        for deployment in dayDeploys {
            guard let commit = deployment.commitOid, !matched.contains(commit), let created = date(deployment.createdAt) else { continue }
            matched.insert(commit)
            let environment = deployment.environment ?? "Production"
            releases.append(Release(id: "deploy-\(commit)-\(environment)", kind: .deployment,
                                    title: "Deployed \(commit.prefix(7)) to \(environment)", detail: environment, actor: nil, at: created,
                                    status: deploymentStatus(deployment),
                                    url: URL(string: "https://github.com/\(repository)/commit/\(commit)"),
                                    target: deployment.latestStatus?.environmentUrl))
        }

        return ShippedDay(day: start, repository: repository, defaultBranch: defaultBranch, you: you, people: people,
                          production: releases.sorted { $0.at > $1.at },
                          merged: pulls.filter { !production.contains($0.base) }.sorted { $0.mergedAt > $1.mergedAt },
                          branches: branches, partial: partial, fetchedAt: now)
    }

    static func deploymentStatus(_ deployment: ShippedGraph.Deployment) -> Release.Status? {
        switch deployment.latestStatus?.state ?? deployment.state {
        case "SUCCESS", "INACTIVE", "ACTIVE": .live
        case "FAILURE", "ERROR": .failed
        case "PENDING", "QUEUED", "IN_PROGRESS": .running
        case "WAITING": .waiting
        default: nil
        }
    }

    static func runStatus(_ status: String?, _ conclusion: String?) -> Release.Status? {
        switch status {
        case "waiting", "action_required": return .waiting
        case "queued", "in_progress", "requested", "pending": return .running
        default: break
        }
        switch conclusion {
        case "success": return .succeeded
        case "failure", "timed_out", "startup_failure": return .failed
        case "cancelled": return .cancelled
        case "action_required": return .waiting
        default: return nil
        }
    }
}

// MARK: Reading GitHub

public enum ShippedReader {
    public enum Failure: Error, Equatable, Sendable {
        case noCLI, signedOut, noRepository, unreachable(String)
        public var title: String {
            switch self {
            case .noCLI: "GitHub CLI not found"
            case .signedOut: "Not signed in to GitHub"
            case .noRepository: "No GitHub repository"
            case .unreachable: "Couldn't read GitHub"
            }
        }
        public var detail: String {
            switch self {
            case .noCLI: "Burro reads GitHub through the gh command. Install it (brew install gh), then run gh auth login."
            case .signedOut: "Run gh auth login in a terminal; Burro uses that sign-in."
            case .noRepository: "The main project's origin remote isn't on GitHub."
            case .unreachable(let message): message
            }
        }
    }

    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    public static func ghExecutable(_ fileManager: FileManager = .default) -> String? {
        ghCandidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// "owner/name" from a GitHub remote URL (https, ssh or scp-style), else nil.
    public static func repository(fromRemote remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["https://", "http://", "ssh://", "git://"]
        if let scheme = prefixes.first(where: { text.hasPrefix($0) }) {
            text.removeFirst(scheme.count)
            if let at = text.firstIndex(of: "@"), at < (text.firstIndex(of: "/") ?? text.endIndex) { text = String(text[text.index(after: at)...]) }
            guard text.hasPrefix("github.com/") else { return nil }
            text.removeFirst("github.com/".count)
        } else if text.hasPrefix("git@github.com:") {
            text.removeFirst("git@github.com:".count)
        } else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// The GitHub repository a local checkout pushes to (its origin remote).
    public static func repository(at path: String, runner: CommandRunner = CommandRunner()) -> String? {
        let result = runner.git(path, ["remote", "get-url", "origin"], timeout: 3)
        return result.succeeded ? repository(fromRemote: result.output) : nil
    }

    /// One day of `repository` from GitHub: about five `gh api` calls, run side by side.
    public static func load(day: Date, repository: String, calendar: Calendar = .current, now: Date = Date(),
                            runner: CommandRunner = CommandRunner()) async -> Result<ShippedDay, Failure> {
        guard let gh = ghExecutable() else { return .failure(.noCLI) }
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return .failure(.noRepository) }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let utc = ISO8601DateFormatter()
        let from = utc.string(from: start), to = utc.string(from: end.addingTimeInterval(-1))

        async let first = Task.detached(priority: .utility) {
            graph(gh, runner, query: firstQuery, variables: ["owner": parts[0], "name": parts[1],
                  "merged": "repo:\(repository) is:pr is:merged merged:\(from)..\(to)",
                  "touched": "repo:\(repository) is:pr updated:>=\(from) sort:updated-asc"])
        }.value
        async let activityPages = Task.detached(priority: .utility) {
            activity(gh, runner, repository: repository, start: start, end: end, now: now)
        }.value
        async let workflowRuns = Task.detached(priority: .utility) {
            let result = runner.run(gh, ["api", "repos/\(repository)/actions/runs?event=workflow_dispatch&per_page=100&exclude_pull_requests=true&created=\(from)..\(to)"], timeout: 20)
            return result.succeeded ? try? JSONDecoder().decode(ShippedRuns.self, from: Data(result.output.utf8)) : nil
        }.value

        let opening = await first
        guard case .success(let page) = opening else {
            if case .failure(let failure) = opening { return .failure(failure) }
            return .failure(.unreachable("GitHub didn't answer."))
        }
        var pages = [page]
        var cursor = page.data?.merged?.pageInfo
        while cursor?.hasNextPage == true, let after = cursor?.endCursor, pages.count < 5 {
            let more = await Task.detached(priority: .utility) {
                graph(gh, runner, query: mergedQuery, variables: ["merged": "repo:\(repository) is:pr is:merged merged:\(from)..\(to)", "after": after])
            }.value
            guard case .success(let next) = more else { break }
            pages.append(next)
            cursor = next.data?.merged?.pageInfo
        }
        let environments = (page.data?.repository?.environments?.nodes ?? []).compactMap(\.name).filter { $0.lowercased().hasPrefix("prod") }
        var deployments: ShippedGraph?
        if !environments.isEmpty {
            let answer = await Task.detached(priority: .utility) {
                graph(gh, runner, query: deploymentsQuery, variables: ["owner": parts[0], "name": parts[1], "envs": environments])
            }.value
            if case .success(let value) = answer { deployments = value }
        }
        let (items, complete) = await activityPages
        let runs = await workflowRuns
        let truncated = !complete || cursor?.hasNextPage == true
        return .success(ShippedDay.build(day: start, end: end, repository: repository, graph: pages, deployments: deployments,
                                         activity: items, runs: runs, partial: truncated, now: now))
    }

    // MARK: Calls

    static let pullFields = """
    number title url state mergedAt baseRefName headRefName additions deletions mergeCommit { oid }
    author { __typename login avatarUrl(size: 64) ... on User { name } }
    """
    static let firstQuery = """
    query($owner: String!, $name: String!, $merged: String!, $touched: String!) {
      viewer { login }
      repository(owner: $owner, name: $name) { defaultBranchRef { name } environments(first: 50) { nodes { name } } }
      merged: search(query: $merged, type: ISSUE, first: 100) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { \(pullFields) } } }
      touched: search(query: $touched, type: ISSUE, first: 100) { nodes { ... on PullRequest { number title url state mergedAt headRefName } } }
    }
    """
    static let mergedQuery = """
    query($merged: String!, $after: String) {
      merged: search(query: $merged, type: ISSUE, first: 100, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { \(pullFields) } } }
    }
    """
    static let deploymentsQuery = """
    query($owner: String!, $name: String!, $envs: [String!]) {
      repository(owner: $owner, name: $name) {
        deployments(environments: $envs, first: 50, orderBy: {field: CREATED_AT, direction: DESC}) {
          nodes { createdAt commitOid environment state latestStatus { state environmentUrl logUrl } }
        }
      }
    }
    """

    static func graph(_ gh: String, _ runner: CommandRunner, query: String, variables: [String: Any]) -> Result<ShippedGraph, Failure> {
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]) else {
            return .failure(.unreachable("Couldn't build the GitHub query."))
        }
        var result = CommandResult(code: -1, output: "", error: "", timedOut: false)
        for attempt in 0..<2 {
            result = runner.run(gh, ["api", "graphql", "--input", "-"], timeout: 25, input: body)
            // gh exits non-zero on GraphQL errors but still prints the answer; keep partial data.
            if let answer = try? JSONDecoder().decode(ShippedGraph.self, from: Data(result.output.utf8)), answer.data != nil {
                return .success(answer)
            }
            // GitHub's search sometimes answers 502 under load; once more after a moment.
            guard attempt == 0, result.error.contains("HTTP 50") || result.timedOut else { break }
            Thread.sleep(forTimeInterval: 1.5)
        }
        return .failure(failure(result))
    }

    static func failure(_ result: CommandResult) -> Failure {
        let text = (result.error + "\n" + result.output).lowercased()
        if text.contains("gh auth login") || text.contains("http 401") || text.contains("bad credentials") { return .signedOut }
        if text.contains("could not resolve to a repository") || text.contains("http 404") { return .noRepository }
        if result.timedOut { return .unreachable("GitHub took too long to answer.") }
        let line = result.error.split(separator: "\n").first.map(String.init) ?? "gh exited with \(result.code)."
        return .unreachable(String(line.prefix(200)))
    }

    /// The repository's activity feed (pushes, merges, branch changes), newest first, read page by page
    /// until it passes the day's start. Returns whether it got that far.
    static func activity(_ gh: String, _ runner: CommandRunner, repository: String, start: Date, end: Date, now: Date) -> ([ShippedActivity], Bool) {
        let age = now.timeIntervalSince(start)
        let period = age <= 86_400 ? "day" : age <= 7 * 86_400 ? "week" : age <= 30 * 86_400 ? "month" : age <= 90 * 86_400 ? "quarter" : "year"
        var path = "repos/\(repository)/activity?per_page=100&time_period=\(period)"
        var kept: [ShippedActivity] = []
        for _ in 0..<15 {
            let result = runner.run(gh, ["api", "-i", path], timeout: 20)
            guard result.succeeded, let (headers, body) = split(result.output),
                  let items = try? JSONDecoder().decode([ShippedActivity].self, from: Data(body.utf8)) else { return (kept, false) }
            let dated = items.compactMap { item in ShippedDay.date(item.timestamp).map { (item, $0) } }
            kept += dated.filter { $0.1 >= start && $0.1 < end }.map(\.0)
            if let oldest = dated.map(\.1).min(), oldest < start { return (kept, true) }
            guard let next = nextLink(headers) else { return (kept, true) }
            path = next
        }
        return (kept, false)
    }

    /// `gh api -i` output: the status line and headers, a blank line, then the body.
    static func split(_ output: String) -> (headers: String, body: String)? {
        for separator in ["\r\n\r\n", "\n\n"] {
            if let range = output.range(of: separator) { return (String(output[..<range.lowerBound]), String(output[range.upperBound...])) }
        }
        return nil
    }

    /// The `rel="next"` link of a Link header, as a path for `gh api`.
    static func nextLink(_ headers: String) -> String? {
        for line in headers.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix("link:") {
            for part in line.dropFirst(5).split(separator: ",") where part.contains("rel=\"next\"") {
                guard let open = part.firstIndex(of: "<"), let close = part.firstIndex(of: ">"), open < close else { continue }
                let url = String(part[part.index(after: open)..<close])
                guard url.hasPrefix("https://api.github.com/") else { return nil }
                return String(url.dropFirst("https://api.github.com/".count))
            }
        }
        return nil
    }
}

// MARK: As text

/// A shipped day as plain Markdown-ish text: for copying into a chat, and for `burro-inspect`.
public enum ShippedText {
    /// `summary` is the written summary for this exact day, when there is one; it follows the headline.
    public static func render(_ day: ShippedDay, summary: String? = nil, recap: [(title: String, text: String)] = [],
                              calendar: Calendar = .current) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        var lines = ["Shipped on \(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(day.repository)", day.headline]
        if let summary, !summary.isEmpty { lines += [""] + ShippedBrief.plain(summary).split(whereSeparator: \.isNewline).map(String.init) }
        for (title, text) in recap where !text.isEmpty {
            lines += ["", title] + ShippedBrief.plain(text).split(whereSeparator: \.isNewline).map { "  " + $0 }
        }
        if !day.production.isEmpty {
            lines += ["", "Production"]
            for release in day.production {
                let who = release.actor.map { " · " + day.person($0).displayName } ?? ""
                let status = release.status.map { " · " + title($0) } ?? ""
                lines.append("- \(release.at.formatted(time)) \(release.title) (\(release.detail))\(who)\(status)")
            }
        }
        let people = day.contributors
        let merged = people.map { ($0, day.merged(by: $0.login)) }.filter { !$0.1.isEmpty }
        if !merged.isEmpty {
            lines += ["", "Merged into \(day.defaultBranch)"]
            for (person, pulls) in merged {
                lines.append("\(person.displayName) (\(pulls.count))")
                for pull in pulls {
                    let into = pull.base == day.defaultBranch ? "" : " → \(pull.base)"
                    lines.append("- \(pull.title) #\(pull.number)\(into)")
                }
            }
        }
        let pushed = people.map { ($0, day.branches(by: $0.login)) }.filter { !$0.1.isEmpty }
        if !pushed.isEmpty {
            lines += ["", "Pushed"]
            for (person, branches) in pushed {
                let pushes = branches.reduce(0) { $0 + $1.pushes }
                lines.append("\(person.displayName): \(ShippedDay.count(pushes, "push")) to \(ShippedDay.count(branches.count, "branch"))")
                for branch in branches {
                    let name = branch.pullRequest.map { "\($0.title) (#\($0.number), \($0.state.lowercased()))" } ?? branch.name
                    lines.append("- \(name) · \(ShippedDay.count(branch.pushes, "push"))")
                }
            }
        }
        if day.partial { lines += ["", "GitHub's lists were long; some pushes or merges may be missing."] }
        return lines.joined(separator: "\n")
    }

    public static func title(_ status: ShippedDay.Release.Status) -> String {
        switch status {
        case .live: "Live"
        case .succeeded: "Succeeded"
        case .running: "Running"
        case .waiting: "Waiting for approval"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
