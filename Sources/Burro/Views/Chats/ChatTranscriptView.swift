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
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcript.truncated {
                        Label("Showing the latest \(transcript.messages.count) messages", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11)).foregroundStyle(AppAppearance.tertiary).frame(maxWidth: .infinity).padding(.bottom, 6)
                    }
                    ForEach(transcript.messages) { message in
                        if let gap = timeBreak(before: message) {
                            Text(gap).font(.system(size: 11, weight: .medium)).foregroundStyle(AppAppearance.tertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        MessageRow(message: message, provider: provider)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: transcript.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            // Follow a reply as it streams in.
            .onChange(of: transcript.messages.last?.text.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
    /// A date/time divider when more than 20 minutes pass between messages.
    private func timeBreak(before message: ChatMessage) -> String? {
        guard let at = message.at else { return nil }
        let previous = transcript.messages.prefix(message.id).last(where: { $0.at != nil })?.at
        guard previous.map({ at.timeIntervalSince($0) > 20 * 60 }) ?? (message.id == 0) else { return nil }
        return Calendar.current.isDateInToday(at) ? at.formatted(date: .omitted, time: .shortened) : at.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct MessageRow: View {
    var message: ChatMessage
    var provider: AgentProvider
    @State private var expanded = false
    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text).font(.system(size: 14)).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(AppAppearance.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        case .assistant:
            MarkdownBlock(text: message.text).padding(.vertical, 2)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Button { if message.output != nil { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 16).foregroundStyle(AppAppearance.tertiary)
                        Text(message.tool ?? "Tool").font(.system(size: 12, weight: .semibold)).foregroundStyle(AppAppearance.secondary)
                        // MCP calls without a useful argument fall back to their full name; don't repeat it.
                        if !message.text.hasPrefix("mcp__") {
                            Text(message.text).font(.system(size: 12, design: .monospaced)).foregroundStyle(AppAppearance.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if message.output != nil {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(AppAppearance.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if expanded, let output = message.output, !output.isEmpty {
                    Text(output).font(.system(size: 11, design: .monospaced)).foregroundStyle(AppAppearance.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(AppAppearance.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.leading, 24)
                }
            }
            .padding(.vertical, 1)
        }
    }
    private var symbol: String {
        switch (message.tool ?? "").lowercased() {
        case "exec", "bash", "shell", "wait": "terminal"
        case "edit", "write", "multiedit", "apply_patch", "notebookedit": "pencil"
        case "read": "doc.text"
        case "grep", "glob", "toolsearch": "magnifyingglass"
        case "webfetch", "websearch": "globe"
        case "agent", "task": "person.2"
        case "overview": "square.grid.2x2"
        case "list_chats": "bubble.left.and.bubble.right"
        case "read_chat": "text.bubble"
        case "list_worktrees": "arrow.triangle.branch"
        case "start_chat": "plus.bubble"
        default: "gearshape"
        }
    }
}

/// Prose with inline Markdown, plus fenced code blocks in monospace.
struct MarkdownBlock: View {
    var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.code {
                    Text(segment.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(AppAppearance.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text(prose(segment.text)).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private var segments: [(text: String, code: Bool)] {
        text.components(separatedBy: "```").enumerated().compactMap { index, part in
            if index % 2 == 1 {
                // Drop the language tag on the fence's first line.
                let lines = part.split(separator: "\n", omittingEmptySubsequences: false)
                let body = lines.count > 1 && !lines[0].contains(" ") ? lines.dropFirst().joined(separator: "\n") : part
                return (body.trimmingCharacters(in: .newlines), true)
            }
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (trimmed, false)
        }
    }
    private func prose(_ text: String) -> AttributedString { Self.inline(text) }
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
