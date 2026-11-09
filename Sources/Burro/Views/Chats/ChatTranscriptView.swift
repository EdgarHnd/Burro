// A chat's conversation, read-only: your messages as bubbles, replies as text with inline
// Markdown and code blocks, and one compact row per tool call (click to see its output).
import SwiftUI
import BurroCore

@MainActor @Observable final class TranscriptLoader {
    private(set) var transcript: ChatTranscript?
    private(set) var error: String?
    private(set) var loading = false
    @ObservationIgnored private var loadedID: String?

    func load(_ session: AgentSession, host: RemoteHost?, profiles: [UsageProvider: String], force: Bool = false) async {
        if loading { return }
        if loadedID != session.id { transcript = nil; error = nil; loadedID = session.id }
        loading = true
        defer { loading = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<ChatTranscript, Error> in
            Result { try ChatTranscripts.load(session, host: host, profiles: profiles) }
        }.value
        guard loadedID == session.id else { return }
        switch result {
        case .success(let value): transcript = value; error = nil
        case .failure(let failure): if transcript == nil { error = (failure as? LocalizedError)?.errorDescription ?? "Couldn't read this chat." }
        }
    }
}

struct ChatTranscriptView: View {
    var transcript: ChatTranscript
    var provider: AgentProvider
    /// The chat is working now: its last turn shows live.
    var working = false
    var body: some View {
        let turns = ConversationTurn.turns(transcript.messages)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    if transcript.truncated {
                        Label("Showing the latest \(transcript.messages.count) messages", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).frame(maxWidth: .infinity)
                    }
                    ForEach(turns) { turn in
                        ChatTurnView(turn: turn, live: working && turn.id == turns.last?.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 36).padding(.vertical, 22)
                .frame(maxWidth: 840).frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: transcript.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            // Follow a reply as it streams in.
            .onChange(of: transcript.messages.last?.text.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

/// One exchange, laid out like the Codex and Claude apps: your message, a "Worked for…" line
/// that opens into every step, then the reply.
private struct ChatTurnView: View {
    var turn: ConversationTurn
    var live: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question = turn.question {
                HStack {
                    Spacer(minLength: 100)
                    Text(question.text).font(.system(size: 14)).textSelection(.enabled)
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            if !turn.steps.isEmpty || (live && turn.answer == nil) {
                WorkedSection(steps: turn.steps, start: turn.question?.at ?? turn.steps.first?.at,
                              end: turn.answer?.at ?? turn.steps.last(where: { $0.at != nil })?.at, live: live && turn.answer == nil)
            }
            if let answer = turn.answer {
                MarkdownBlock(text: answer.text, size: 14.5)
            }
        }
    }
}

private struct WorkedSection: View {
    var steps: [ChatMessage]
    var start: Date?
    var end: Date?
    var live: Bool
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    if live { ProgressView().controlSize(.mini) }
                    if live, let start {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Working for \(Self.duration(context.date.timeIntervalSince(start)))")
                        }
                    } else {
                        Text(label)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(AppAppearance.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle().fill(AppAppearance.separator).frame(height: 1).padding(.top, 10)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(steps) { step in ChatStepRow(step: step) }
                }
                .padding(.top, 12)
            }
        }
    }
    /// Open while the chat works (like Codex's live view); folded once it has answered.
    private var expanded: Bool { open || (live && steps.count <= 12) }
    private var label: String {
        if let start, let end, end > start { return "Worked for \(Self.duration(end.timeIntervalSince(start)))" }
        let tools = steps.filter { $0.kind == .tool }.count
        return tools == 1 ? "1 step" : "\(tools) steps"
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// A step inside "Worked for…": a note the agent wrote, or a tool call (click for its output).
private struct ChatStepRow: View {
    var step: ChatMessage
    @State private var expanded = false
    var body: some View {
        if step.kind == .tool {
            VStack(alignment: .leading, spacing: 6) {
                Button { if step.output?.isEmpty == false { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 16).foregroundStyle(AppAppearance.tertiary)
                        Text(verb).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if step.output?.isEmpty == false {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded, let output = step.output, !output.isEmpty {
                    Text(output).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(AppAppearance.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.leading, 24)
                }
            }
        } else {
            MarkdownBlock(text: step.text, size: 13).foregroundStyle(AppAppearance.secondary).padding(.vertical, 2)
        }
    }
    private var name: String { (step.tool ?? "").lowercased() }
    /// What the call did, in a word.
    private var verb: String {
        if step.text.hasPrefix("// @exec") || name == "wait" { return "Waited" }
        if step.text.contains("write_stdin") { return "Sent input" }
        switch name {
        case "exec", "bash", "shell", "exec_command", "local_shell": return "Ran"
        case "edit", "write", "multiedit", "apply_patch", "notebookedit": return "Edited"
        case "read", "view_image": return "Read"
        case "grep", "glob", "toolsearch": return "Searched"
        case "webfetch", "websearch", "web_search": return "Browsed"
        case "agent", "task", "spawn_agent": return "Delegated"
        case "todowrite", "update_plan": return "Updated the plan"
        default: return step.tool ?? "Tool"
        }
    }
    private var detail: String {
        if step.text.hasPrefix("// @exec") || step.text.contains("write_stdin") || step.text.hasPrefix("mcp__") { return "" }
        if ["read", "edit", "write", "multiedit"].contains(name), step.text.hasPrefix("/") { return URL(fileURLWithPath: step.text).lastPathComponent }
        return step.text == step.tool ? "" : step.text
    }
    private var symbol: String {
        switch verb {
        case "Ran", "Waited", "Sent input": "terminal"
        case "Edited": "pencil"
        case "Read": "doc.text"
        case "Searched": "magnifyingglass"
        case "Browsed": "globe"
        case "Delegated": "person.2"
        case "Updated the plan": "checklist"
        default: "gearshape"
        }
    }
}

/// Markdown for chat replies: headings, bullet and numbered lists, paragraphs with inline
/// styling, fenced code blocks in monospace, and images or videos linked by absolute path.
/// Parsed per render from the message text.
struct MarkdownBlock: View {
    var text: String
    var size: CGFloat = 14
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    Text(code).font(.system(size: size - 2, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(AppAppearance.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .heading(let line, let level):
                    Text(Self.inline(line)).font(.system(size: level <= 1 ? size + 4 : size + 1, weight: .semibold))
                        .padding(.top, 4).frame(maxWidth: .infinity, alignment: .leading)
                case .item(let marker, let line, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).font(.system(size: size, weight: .medium)).monospacedDigit().foregroundStyle(AppAppearance.tertiary)
                            .frame(width: 18, alignment: .trailing)
                        Text(Self.inline(line)).font(.system(size: size)).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                case .paragraph(let line):
                    Text(Self.inline(line)).font(.system(size: size)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .media(let caption, let path):
                    ChatMediaView(caption: caption, path: path).padding(.vertical, 4)
                }
            }
        }
    }

    enum Block: Equatable { case code(String), heading(String, Int), item(String, String, Int), paragraph(String), media(String, String) }

    /// `![caption](/absolute/path.png)` links to an image or video file; other images stay as text.
    nonisolated static func media(in line: String) -> (rest: String, media: [(String, String)])? {
        var media: [(String, String)] = []
        var rest = line
        for match in line.matches(of: /!\[([^\]]*)\]\(<?(?:file:\/\/)?(\/[^)>]+?)>?\)/) {
            let path = String(match.2).removingPercentEncoding ?? String(match.2)
            guard ChatMedia.kind(of: path) != nil else { continue }
            media.append((String(match.1), path))
            rest = rest.replacingOccurrences(of: String(match.0), with: "")
        }
        return media.isEmpty ? nil : (rest.trimmingCharacters(in: .whitespaces), media)
    }

    nonisolated static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        for (index, part) in text.components(separatedBy: "```").enumerated() {
            if index % 2 == 1 {
                // Drop the language tag on the fence's first line.
                let lines = part.split(separator: "\n", omittingEmptySubsequences: false)
                let body = lines.count > 1 && !lines[0].contains(" ") ? lines.dropFirst().joined(separator: "\n") : part
                blocks.append(.code(body.trimmingCharacters(in: .newlines)))
                continue
            }
            var paragraph: [String] = []
            func flush() {
                let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { blocks.append(.paragraph(joined)) }
                paragraph = []
            }
            for raw in part.components(separatedBy: "\n") {
                let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush(); continue }
                if let found = media(in: line) {
                    flush()
                    if !found.rest.isEmpty { blocks.append(.paragraph(found.rest)) }
                    blocks += found.media.map { Block.media($0.0, $0.1) }
                    continue
                }
                if let match = line.wholeMatch(of: /(#{1,6})\s+(.+)/) {
                    flush(); blocks.append(.heading(String(match.2), match.1.count)); continue
                }
                if let match = line.wholeMatch(of: /[-*•]\s+(.+)/) {
                    flush(); blocks.append(.item("•", String(match.1), indent / 2)); continue
                }
                if let match = line.wholeMatch(of: /(\d{1,3})[.)]\s+(.+)/) {
                    flush(); blocks.append(.item(match.1 + ".", String(match.2), indent / 2)); continue
                }
                paragraph.append(line)
            }
            flush()
        }
        return blocks
    }

    nonisolated static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
