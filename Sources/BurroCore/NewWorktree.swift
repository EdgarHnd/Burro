// "Start in a new worktree" from the New chat sheet. Only the owner's Start creates one, and only
// for a git project on this Mac. The branch is named from the prompt's first words with the
// provider in front, the way this Mac's agent worktrees are already named ("claude/<words>",
// "codex/<words>"), and the folder goes next to the repository's main checkout under
// "<repository>-worktrees/<words>", the folder this Mac's Claude worktrees already use. A name
// whose branch or folder is taken gets "-2", "-3"… The new branch starts at the project folder's
// current commit. When the project is a subfolder of its checkout, the chat starts in the same
// subfolder of the new worktree (when it exists there; else at the worktree's root). Right before
// `git worktree add`, the chosen branch and folder are checked again and the attempt stops if
// either appeared meanwhile; if git then fails because one of them already exists, nothing is
// touched (it isn't this attempt's). Otherwise, if anything fails, what this attempt made is undone
// (the new folder's registration and checkout, the new branch while it still points at the base,
// the folders it created when empty) and the error says what happened and anything it couldn't
// undo; the chat is then not started. `discard` undoes an unused worktree the same way (without
// forcing) when its Starting row was dismissed before the chat started.
import Foundation

public struct NewWorktreePlan: Equatable, Sendable {
    public var slug: String
    public var branch: String
    public var path: String
}

public struct CreatedWorktree: Equatable, Sendable {
    public var path: String
    public var branch: String
    /// The repository's main checkout.
    public var repository: String
    /// The commit the branch starts at.
    public var base: String
    /// Where the chat starts: the project's subfolder inside the worktree, or its root.
    public var folder: String
    /// The "<repository>-worktrees" folder, when this attempt created it.
    public var createdParent: String?
}

public enum NewWorktreeError: Error, LocalizedError, Equatable {
    case missingFolder, notRepository, bareRepository, noCommits, noFreeName, nameTakenMeanwhile
    case gitFailed(String, leftovers: [String])
    public var errorDescription: String? {
        switch self {
        case .missingFolder: "The project folder no longer exists."
        case .notRepository: "The project isn't a git repository."
        case .bareRepository: "The repository has no main checkout to branch from."
        case .noCommits: "The repository has no commits yet, so there is nothing to branch from."
        case .noFreeName: "Every branch name made from this prompt is taken. Change the prompt's first words."
        case .nameTakenMeanwhile: "The branch or folder Burro picked was created by something else just now. Nothing was changed; try again."
        case .gitFailed(let reason, let leftovers):
            reason + (leftovers.isEmpty ? "" : " Left behind, to remove yourself: " + leftovers.joined(separator: ", ") + ".")
        }
    }
}

public enum NewWorktree {
    static let stopWords: Set<String> = [
        "a", "an", "the", "in", "on", "of", "to", "and", "or", "for", "with", "at", "by", "from", "into", "is", "are", "be",
        "it", "its", "this", "that", "these", "those", "my", "our", "your", "i", "we", "you", "me", "us", "please", "can",
        "could", "would", "should", "will", "just", "so", "then", "there", "here", "some", "any", "all",
    ]
    static let wordLimit = 4
    static let slugLimit = 40
    static let attempts = 50

    /// The prompt's first meaningful words as a branch-safe slug: lowercase ASCII letters and digits
    /// joined by "-", at most four words and 40 characters; "chat" when nothing usable is left.
    public static func slug(from prompt: String) -> String {
        let folded = prompt.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = folded.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init).filter { !stopWords.contains($0) }
        var slug = ""
        for word in words.prefix(wordLimit) {
            let next = slug.isEmpty ? word : slug + "-" + word
            if next.count > slugLimit {
                if slug.isEmpty { slug = String(word.prefix(slugLimit)) }
                break
            }
            slug = next
        }
        return slug.isEmpty ? "chat" : slug
    }

    /// The branch for a slug: the provider in front, as this Mac's agent worktrees are named.
    public static func branch(slug: String, provider: LaunchProvider) -> String { "\(provider.rawValue)/\(slug)" }

    /// The branch the sheet shows under the switch (before any "-2" a taken name would get).
    public static func branchName(prompt: String, provider: LaunchProvider) -> String { branch(slug: slug(from: prompt), provider: provider) }

    /// The folder for a slug: "<parent of the main checkout>/<repository name>-worktrees/<slug>".
    public static func folder(repository: String, slug: String) -> String {
        let main = URL(fileURLWithPath: repository).standardizedFileURL
        return main.deletingLastPathComponent().appendingPathComponent(main.lastPathComponent + "-worktrees").appendingPathComponent(slug).path
    }

    /// The first free name: the slug, then "-2", "-3"… where neither the branch nor the folder is taken.
    public static func plan(prompt: String, provider: LaunchProvider, repository: String,
                            branchTaken: (String) -> Bool, pathTaken: (String) -> Bool) -> NewWorktreePlan? {
        let base = slug(from: prompt)
        for attempt in 1...attempts {
            let slug = attempt == 1 ? base : "\(base)-\(attempt)"
            let branch = branch(slug: slug, provider: provider), path = folder(repository: repository, slug: slug)
            if !branchTaken(branch), !pathTaken(path) { return NewWorktreePlan(slug: slug, branch: branch, path: path) }
        }
        return nil
    }

    /// The folder a chat starts in: `project`'s place relative to its own checkout (`checkout`, the
    /// checkout's top folder), inside the new `worktree`, when that folder exists there; else the
    /// worktree's root. Paths are compared as given (pass canonical ones).
    public static func startFolder(project: String, checkout: String, worktree: String, exists: (String) -> Bool) -> String {
        let root = checkout.hasSuffix("/") ? String(checkout.dropLast()) : checkout
        guard !root.isEmpty, project.hasPrefix(root + "/") else { return worktree }
        let relative = project.dropFirst(root.count + 1).split(separator: "/").filter { !$0.isEmpty && $0 != "." }
        guard !relative.isEmpty, !relative.contains("..") else { return worktree }
        let candidate = relative.reduce(URL(fileURLWithPath: worktree)) { $0.appendingPathComponent(String($1)) }.path
        return exists(candidate) ? candidate : worktree
    }

    /// Whether a folder on this Mac is inside a git checkout (reads `.git` markers only; cheap).
    public static func isGitProject(_ folder: String) -> Bool {
        !folder.isEmpty && Scanner.gitMarker(above: folder).found
    }

    /// Creates the worktree for a chat started from `project` (blocking; call it off the main thread).
    public static func create(in project: String, prompt: String, provider: LaunchProvider,
                              runner: CommandRunner = CommandRunner()) throws -> CreatedWorktree {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: project, isDirectory: &isDirectory), isDirectory.boolValue else { throw NewWorktreeError.missingFolder }
        let listing = runner.git(project, ["worktree", "list", "--porcelain", "-z"])
        guard listing.succeeded, let main = GitParser.worktrees(listing.output).first else { throw NewWorktreeError.notRepository }
        guard !main.bare else { throw NewWorktreeError.bareRepository }
        let head = runner.git(project, ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
        let base = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.succeeded, !base.isEmpty else { throw NewWorktreeError.noCommits }
        let registered = Set(GitParser.worktrees(listing.output).map(\.path))
        guard let plan = plan(prompt: prompt, provider: provider, repository: main.path,
                              branchTaken: { runner.git(project, ["show-ref", "--verify", "--quiet", "refs/heads/" + $0]).code == 0 },
                              pathTaken: { fm.fileExists(atPath: $0) || registered.contains(Paths.canonical($0)) }) else {
            throw NewWorktreeError.noFreeName
        }
        // Checked again right before adding: only a branch and folder that don't exist now are this attempt's to undo.
        guard runner.git(project, ["show-ref", "--verify", "--quiet", "refs/heads/" + plan.branch]).code != 0,
              !fm.fileExists(atPath: plan.path), registration(of: plan.path, in: project, runner: runner) == nil else {
            throw NewWorktreeError.nameTakenMeanwhile
        }
        let parent = URL(fileURLWithPath: plan.path).deletingLastPathComponent().path
        let madeParent = !fm.fileExists(atPath: parent)
        let add = runner.git(project, ["worktree", "add", "-b", plan.branch, plan.path, base], timeout: 180)
        if add.succeeded, let record = registration(of: plan.path, in: project, runner: runner), record.branch == plan.branch {
            let top = runner.git(project, ["rev-parse", "--show-toplevel"])
            let checkout = top.succeeded ? Paths.canonical(top.output.trimmingCharacters(in: .whitespacesAndNewlines)) : ""
            let folder = startFolder(project: Paths.canonical(project), checkout: checkout, worktree: record.path) { path in
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            return CreatedWorktree(path: record.path, branch: plan.branch, repository: main.path, base: base,
                                   folder: folder, createdParent: madeParent ? parent : nil)
        }
        let message = add.error.isEmpty ? add.output : add.error
        let reason = add.succeeded ? "Git reported success but the worktree isn't registered."
            : add.timedOut ? "Git took too long to check out the worktree."
            : gitReason(message)
        // Git refused because the branch or folder exists: something else made it, so leave it be.
        if !add.succeeded, !add.timedOut, message.contains("already exists") {
            throw NewWorktreeError.gitFailed(reason, leftovers: [])
        }
        let leftovers = undo(plan, base: base, parent: madeParent ? parent : nil, project: project, runner: runner)
        throw NewWorktreeError.gitFailed(reason, leftovers: leftovers)
    }

    /// Undoes a worktree `create` made that was never used (its Starting row was dismissed): the
    /// same undo as after a failure, but git's own safety check stays on (no `--force`). Returns
    /// what is still there. Blocking; call it off the main thread.
    @discardableResult
    public static func discard(_ tree: CreatedWorktree, runner: CommandRunner = CommandRunner()) -> [String] {
        let plan = NewWorktreePlan(slug: URL(fileURLWithPath: tree.path).lastPathComponent, branch: tree.branch, path: tree.path)
        return undo(plan, base: tree.base, parent: tree.createdParent, project: tree.repository, runner: runner, force: false)
    }

    static func registration(of path: String, in project: String, runner: CommandRunner) -> WorktreeRecord? {
        let listing = runner.git(project, ["worktree", "list", "--porcelain", "-z"])
        guard listing.succeeded else { return nil }
        let canonical = Paths.canonical(path)
        return GitParser.worktrees(listing.output).first { $0.path == canonical }
    }

    /// Git's message without the "fatal:" prefix, first line only.
    static func gitReason(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        var reason = line
        for prefix in ["fatal: ", "error: "] where reason.hasPrefix(prefix) { reason = String(reason.dropFirst(prefix.count)) }
        guard !reason.isEmpty else { return "Git couldn't create the worktree." }
        return "Git couldn't create the worktree: " + reason + (reason.hasSuffix(".") ? "" : ".")
    }

    /// Removes what this attempt made: its registration and checkout (only the new path), the new
    /// branch while it still points at `base`, and folders it created if they are empty. Returns
    /// what is still there.
    static func undo(_ plan: NewWorktreePlan, base: String, parent: String?, project: String, runner: CommandRunner, force: Bool = true) -> [String] {
        let fm = FileManager.default
        var left: [String] = []
        if registration(of: plan.path, in: project, runner: runner) != nil {
            _ = runner.git(project, ["worktree", "remove"] + (force ? ["--force"] : []) + [plan.path], timeout: 60)
        }
        let stillRegistered = registration(of: plan.path, in: project, runner: runner) != nil
        if stillRegistered { left.append("the worktree registration " + plan.path) }
        // A branch still checked out in a remaining worktree stays (with it).
        if stillRegistered {
            left.append("the branch " + plan.branch)
        } else if runner.git(project, ["show-ref", "--verify", "--quiet", "refs/heads/" + plan.branch]).code == 0 {
            // Deleted only while it still points where this attempt made it.
            _ = runner.git(project, ["update-ref", "-d", "refs/heads/" + plan.branch, base])
            if runner.git(project, ["show-ref", "--verify", "--quiet", "refs/heads/" + plan.branch]).code == 0 { left.append("the branch " + plan.branch) }
        }
        for folder in [plan.path, parent].compactMap({ $0 }) where fm.fileExists(atPath: folder) {
            if (try? fm.contentsOfDirectory(atPath: folder))?.isEmpty == true { try? fm.removeItem(atPath: folder) }
        }
        if fm.fileExists(atPath: plan.path) { left.append("the folder " + plan.path) }
        return left
    }
}
