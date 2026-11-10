// Many days of a repository's GitHub history at once, for backfilling the written summaries.
// Reading day by day would cost a few hundred searches and re-read the activity feed each time;
// this reads each kind of data once for the whole range (merged and opened pull requests a week
// at a time, the activity feed in one pass, production deployments and workflow runs page by
// page), backs off when GitHub rate-limits, and then builds each day locally with the same
// ShippedDay.build the Today page uses. Read-only, through the GitHub CLI's own sign-in.
import Foundation

public enum ShippedHistory {
    public struct Range: Sendable {
        var head: ShippedGraph
        var merged: [ShippedGraph.Pull]
        var touched: [ShippedGraph.Pull]
        var deployments: [ShippedGraph.Deployment]
        var activity: [ShippedActivity]
        var runs: [ShippedRuns.Run]
        public var activityComplete: Bool
        public var start: Date
        public var end: Date
        public var repository: String
        public var requests: Int
        public var mergedCount: Int { merged.count }
        public var activityCount: Int { activity.count }
    }

    /// When the repository was created on GitHub.
    public static func createdAt(_ repository: String, runner: CommandRunner = CommandRunner()) -> Date? {
        guard let gh = ShippedReader.ghExecutable() else { return nil }
        let result = call(gh, runner, ["api", "repos/\(repository)", "--jq", ".created_at"], log: { _ in })
        return result.succeeded ? ShippedDay.date(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    /// Everything from the start of `from`'s day to the end of `to`'s day.
    public static func load(repository: String, from: Date, to: Date, calendar: Calendar = .current, now: Date = Date(),
                            runner: CommandRunner = CommandRunner(), log: @escaping @Sendable (String) -> Void) async -> Result<Range, ShippedReader.Failure> {
        guard let gh = ShippedReader.ghExecutable() else { return .failure(.noCLI) }
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return .failure(.noRepository) }
        let start = calendar.startOfDay(for: from)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to)) ?? to
        let counter = Counter()

        let head: ShippedGraph
        switch graph(gh, runner, counter, query: headQuery, variables: ["owner": parts[0], "name": parts[1]], log: log) {
        case .success(let value): head = value
        case .failure(let failure): return .failure(failure)
        }
        let environments = (head.data?.repository?.environments?.nodes ?? []).compactMap(\.name).filter { $0.lowercased().hasPrefix("prod") }

        // The four readers are independent: run them side by side.
        async let mergedPulls = Task.detached(priority: .utility) {
            search(gh, runner, counter, repository: repository, qualifier: "is:merged merged", start: start, end: end, calendar: calendar, log: log)
        }.value
        async let openedPulls = Task.detached(priority: .utility) {
            search(gh, runner, counter, repository: repository, qualifier: "created", start: start, end: end, calendar: calendar, log: log)
        }.value
        async let feed = Task.detached(priority: .utility) {
            activity(gh, runner, counter, repository: repository, start: start, log: log)
        }.value
        async let production = Task.detached(priority: .utility) {
            (deployments(gh, runner, counter, owner: parts[0], name: parts[1], environments: environments, start: start, log: log),
             runs(gh, runner, counter, repository: repository, start: start, end: end, calendar: calendar, log: log))
        }.value

        let merged = await mergedPulls, opened = await openedPulls
        let (items, complete) = await feed
        let (deploys, workflowRuns) = await production
        guard let merged else { return .failure(.unreachable("Couldn't read the merged pull requests.")) }
        var touched = opened ?? []
        // Pull requests still open from before the range (rare) name branches too.
        if let open = search(gh, runner, counter, repository: repository, qualifier: "is:open created", start: .distantPast, end: start, calendar: calendar, log: log) {
            touched += open
        }
        return .success(Range(head: head, merged: merged, touched: touched, deployments: deploys, activity: items, runs: workflowRuns,
                              activityComplete: complete, start: start, end: end, repository: repository, requests: counter.value))
    }

    /// Each day of the range, oldest first, as the Shipped section would read it.
    public static func days(_ range: Range, calendar: Calendar = .current, now: Date = Date()) -> [ShippedDay] {
        func dayOf(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        var activity: [Date: [ShippedActivity]] = [:]
        for item in range.activity { if let at = ShippedDay.date(item.timestamp) { activity[dayOf(at), default: []].append(item) } }
        var merged: [Date: [ShippedGraph.Pull]] = [:]
        for pull in range.merged { if let at = ShippedDay.date(pull.mergedAt) { merged[dayOf(at), default: []].append(pull) } }
        var runs: [Date: [ShippedRuns.Run]] = [:]
        for run in range.runs { if let at = ShippedDay.date(run.created_at) { runs[dayOf(at), default: []].append(run) } }
        // Pull requests by branch, for naming each day's pushed branches.
        var byHead: [String: [ShippedGraph.Pull]] = [:]
        var seen = Set<Int>()
        for pull in range.touched + range.merged {
            guard let head = pull.headRefName, let number = pull.number, seen.insert(number).inserted else { continue }
            byHead[head, default: []].append(pull)
        }
        let deployments = ShippedGraph(data: .init(viewer: nil, repository: .init(defaultBranchRef: nil, environments: nil,
                                                                                deployments: .init(nodes: range.deployments)),
                                                   merged: nil, touched: nil), errors: nil)
        let workflowRuns = { (day: Date) in ShippedRuns(workflow_runs: runs[day] ?? []) }
        // Names GitHub gave for pull request authors anywhere in the range, for people who only
        // pushed on a day (the activity feed has logins only).
        var names: [String: String] = [:]
        for pull in range.merged + range.touched {
            if let login = pull.author?.login, let name = pull.author?.name, !name.isEmpty, name != login { names[login] = name }
        }

        var days: [ShippedDay] = []
        var day = range.start
        while day < range.end {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let items = activity[day] ?? []
            let heads = Set(items.compactMap { $0.ref.map { String($0.dropFirst("refs/heads/".count)) } })
            let candidates = heads.flatMap { byHead[$0] ?? [] }
            let page = ShippedGraph(data: .init(viewer: range.head.data?.viewer, repository: range.head.data?.repository,
                                                merged: .init(issueCount: nil, pageInfo: nil, nodes: merged[day] ?? []),
                                                touched: .init(issueCount: nil, pageInfo: nil, nodes: candidates)), errors: nil)
            var built = ShippedDay.build(day: day, end: next, repository: range.repository, graph: [page], deployments: deployments,
                                         activity: items, runs: workflowRuns(day), partial: !range.activityComplete, now: now)
            for (login, person) in built.people where person.name == nil { built.people[login]?.name = names[login] }
            days.append(built)
            day = next
        }
        return days
    }

    // MARK: Reading

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    static let headQuery = """
    query($owner: String!, $name: String!) {
      viewer { login }
      repository(owner: $owner, name: $name) { defaultBranchRef { name } environments(first: 50) { nodes { name } } }
    }
    """
    /// Like the Today page's search, 40 at a time: a page of 100 with line counts makes GitHub
    /// time out (HTTP 502) on a busy week.
    static let searchQuery = """
    query($merged: String!, $after: String) {
      merged: search(query: $merged, type: ISSUE, first: 40, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { \(ShippedReader.pullFields) } } }
    }
    """
    static let deploymentsPageQuery = """
    query($owner: String!, $name: String!, $envs: [String!], $after: String) {
      repository(owner: $owner, name: $name) {
        deployments(environments: $envs, first: 100, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes { createdAt commitOid environment state latestStatus { state environmentUrl logUrl } }
        }
      }
    }
    """

    /// One `gh` call, tried again when GitHub is busy: a minute and more after a rate limit
    /// (longer each time), a few seconds after a server error.
    static func call(_ gh: String, _ runner: CommandRunner, _ arguments: [String], input: Data? = nil, counter: Counter? = nil,
                     log: (String) -> Void) -> CommandResult {
        var result = CommandResult(code: -1, output: "", error: "", timedOut: false)
        for attempt in 0..<6 {
            counter?.add()
            result = runner.run(gh, arguments, timeout: 40, input: input)
            if result.succeeded { return result }
            let text = (result.error + "\n" + result.output.prefix(2000)).lowercased()
            let limited = text.contains("rate limit") || text.contains("http 429") || text.contains("secondary") || text.contains("abuse")
            let busy = text.contains("http 50") || text.contains("timeout") || result.timedOut
            // GraphQL errors (gh exits 1 but prints data) are the caller's to read.
            if !limited && !busy { return result }
            guard attempt < 5 else { break }
            let wait = limited ? 60.0 * Double(attempt + 1) : 3.0 * Double(attempt + 1)
            log("GitHub is \(limited ? "rate-limiting" : "busy"); waiting \(Int(wait)) s")
            Thread.sleep(forTimeInterval: wait)
        }
        return result
    }

    static func graph(_ gh: String, _ runner: CommandRunner, _ counter: Counter, query: String, variables: [String: Any],
                      log: (String) -> Void) -> Result<ShippedGraph, ShippedReader.Failure> {
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]) else {
            return .failure(.unreachable("Couldn't build the GitHub query."))
        }
        let result = call(gh, runner, ["api", "graphql", "--input", "-"], input: body, counter: counter, log: log)
        if let answer = try? JSONDecoder().decode(ShippedGraph.self, from: Data(result.output.utf8)), answer.data != nil { return .success(answer) }
        return .failure(ShippedReader.failure(result))
    }

    /// Pull requests whose `qualifier` date (merged, created) falls in the range, a week of
    /// searches at a time (GitHub stops a search at 1,000 results).
    static func search(_ gh: String, _ runner: CommandRunner, _ counter: Counter, repository: String, qualifier: String,
                       start: Date, end: Date, calendar: Calendar, log: (String) -> Void) -> [ShippedGraph.Pull]? {
        let utc = ISO8601DateFormatter()
        var pulls: [ShippedGraph.Pull] = []
        var chunk = start
        while chunk < end {
            let next = start == .distantPast ? end : min(end, calendar.date(byAdding: .day, value: 7, to: chunk) ?? end)
            let range = start == .distantPast ? "<\(utc.string(from: end))" : "\(utc.string(from: chunk))..\(utc.string(from: next.addingTimeInterval(-1)))"
            let text = "repo:\(repository) is:pr \(qualifier):\(range)"
            var cursor: String?
            var pages = 0
            repeat {
                var variables: [String: Any] = ["merged": text]
                if let cursor { variables["after"] = cursor }
                guard case .success(let page) = graph(gh, runner, counter, query: searchQuery, variables: variables, log: log) else { return nil }
                pulls += page.data?.merged?.nodes ?? []
                if pages == 0, let count = page.data?.merged?.issueCount, count > 1000 {
                    log("More than 1,000 pull requests between \(range); some are missing")
                }
                cursor = page.data?.merged?.pageInfo?.hasNextPage == true ? page.data?.merged?.pageInfo?.endCursor : nil
                pages += 1
            } while cursor != nil && pages < 26
            chunk = next
        }
        return pulls
    }

    /// The activity feed back to `start`, newest first; whether it got that far.
    static func activity(_ gh: String, _ runner: CommandRunner, _ counter: Counter, repository: String, start: Date,
                         log: (String) -> Void) -> ([ShippedActivity], Bool) {
        var path = "repos/\(repository)/activity?per_page=100&time_period=year"
        var kept: [ShippedActivity] = []
        for page in 0..<600 {
            let result = call(gh, runner, ["api", "-i", path], counter: counter, log: log)
            guard result.succeeded, let (headers, body) = ShippedReader.split(result.output),
                  let items = try? JSONDecoder().decode([ShippedActivity].self, from: Data(body.utf8)) else { return (kept, false) }
            let dated = items.compactMap { item in ShippedDay.date(item.timestamp).map { (item, $0) } }
            kept += dated.filter { $0.1 >= start }.map(\.0)
            if page % 20 == 19 { log("Activity: \(kept.count) events read, back to \(dated.last.map { ShippedSummary.stamp($0.1, "yyyy-MM-dd", calendar: .current) } ?? "?")") }
            if let oldest = dated.map(\.1).min(), oldest < start { return (kept, true) }
            guard let next = ShippedReader.nextLink(headers) else { return (kept, true) }
            path = next
        }
        return (kept, false)
    }

    /// Production deployments back to `start`.
    static func deployments(_ gh: String, _ runner: CommandRunner, _ counter: Counter, owner: String, name: String,
                            environments: [String], start: Date, log: (String) -> Void) -> [ShippedGraph.Deployment] {
        guard !environments.isEmpty else { return [] }
        var kept: [ShippedGraph.Deployment] = []
        var cursor: String?
        for _ in 0..<50 {
            var variables: [String: Any] = ["owner": owner, "name": name, "envs": environments]
            if let cursor { variables["after"] = cursor }
            guard case .success(let page) = graph(gh, runner, counter, query: deploymentsPageQuery, variables: variables, log: log),
                  let list = page.data?.repository?.deployments else { break }
            let nodes = list.nodes ?? []
            kept += nodes
            if let oldest = nodes.compactMap({ ShippedDay.date($0.createdAt) }).min(), oldest < start { break }
            guard list.pageInfo?.hasNextPage == true, let next = list.pageInfo?.endCursor else { break }
            cursor = next
        }
        return kept
    }

    /// Manually started workflow runs (where production runs live), a month at a time.
    static func runs(_ gh: String, _ runner: CommandRunner, _ counter: Counter, repository: String, start: Date, end: Date,
                     calendar: Calendar, log: (String) -> Void) -> [ShippedRuns.Run] {
        let utc = ISO8601DateFormatter()
        var kept: [ShippedRuns.Run] = []
        var chunk = start
        while chunk < end {
            let next = min(end, calendar.date(byAdding: .month, value: 1, to: chunk) ?? end)
            let range = "\(utc.string(from: chunk))..\(utc.string(from: next.addingTimeInterval(-1)))"
            for page in 1...10 {
                let result = call(gh, runner, ["api", "repos/\(repository)/actions/runs?event=workflow_dispatch&per_page=100&exclude_pull_requests=true&created=\(range)&page=\(page)"],
                                  counter: counter, log: log)
                guard result.succeeded, let answer = try? JSONDecoder().decode(ShippedRuns.self, from: Data(result.output.utf8)) else { break }
                let list = answer.workflow_runs ?? []
                kept += list
                if list.count < 100 { break }
            }
            chunk = next
        }
        return kept
    }
}
