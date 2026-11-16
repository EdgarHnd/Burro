// Sends replies you queued with "Queue for when it's done". AppStore hands it every published
// sample; a queued message goes once its chat has looked idle for a few seconds (`ReplyQueue`
// decides), through `ChatReply.send`, which re-runs a normal reply's checks (the machine is
// configured and answering, a Claude session isn't open elsewhere; an idle Claude background
// session is stopped and continued, as the composer's Send does). The message is marked as going
// (saved) before it is sent, so a relaunch never sends it twice. Success or failure leaves a
// notice on the chat; a failed message keeps its text so you can edit it back. A send the provider
// refuses because the chat is working or waiting after all stays queued and goes when the chat is
// next idle (`ReplyQueue.requeue`). One whose outcome Burro couldn't confirm (`ReplyNotConfirmed`:
// it may have reached the chat) is never retried, and its notice says so. Nothing is sent
// that you didn't queue, and a queued message can be cancelled or edited until it goes.
import Foundation
import Observation
import BurroCore

@MainActor @Observable
final class ReplyQueueModel {
    static let shared = ReplyQueueModel()
    private(set) var queue: ReplyQueue
    /// Chats whose queued message is being sent right now.
    private(set) var sending: Set<String> = []
    @ObservationIgnored private let store: ReplyQueueStore
    @ObservationIgnored private var missingSince: [String: Date] = [:]
    @ObservationIgnored private var idleSince: [String: Date] = [:]

    init(store: ReplyQueueStore = .standard) {
        self.store = store
        queue = store.load()
    }

    func item(for chatID: String) -> QueuedReply? { queue.item(for: chatID) }
    func notice(for chatID: String) -> ReplyQueueNotice? { queue.notice(for: chatID) }

    /// Queues the message (your explicit action). Throws when one already waits for this chat.
    func enqueue(_ request: ReplyRequest, for chatID: String) throws {
        var next = queue
        try next.enqueue(QueuedReply(chatID: chatID, request: request, queuedAt: Date()))
        next.dismissNotice(chatID: chatID)
        commit(next)
    }

    /// Removes the queued message and returns it (Cancel, or Edit to put it back in the composer).
    @discardableResult
    func cancel(_ chatID: String) -> QueuedReply? {
        guard !sending.contains(chatID) else { return nil }
        var next = queue
        let item = next.cancel(chatID: chatID)
        commit(next)
        return item
    }

    func dismissNotice(_ chatID: String) {
        var next = queue
        next.dismissNotice(chatID: chatID)
        commit(next)
    }

    /// Called with each published sample of chats.
    func update(sessions: [AgentSession], hosts: [RemoteHost]) {
        guard !queue.items.isEmpty else { missingSince = [:]; idleSince = [:]; return }
        let now = Date()
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in queue.items where !sending.contains(item.chatID) {
            let session = byID[item.chatID]
            if session == nil { missingSince[item.chatID] = missingSince[item.chatID] ?? now } else { missingSince[item.chatID] = nil }
            if let session, [.idle, .recent, .inactive].contains(session.state) { idleSince[item.chatID] = idleSince[item.chatID] ?? now }
            else { idleSince[item.chatID] = nil }
            switch ReplyQueue.decision(item, session: session, missingSince: missingSince[item.chatID], idleSince: idleSince[item.chatID], now: now) {
            case .wait: continue
            case .drop(let reason): finish(item, sent: false, message: reason)
            case .dispatch:
                guard let session else { continue }
                dispatch(item, to: session, host: hosts.first { $0.id == session.remote?.hostID })
            }
        }
    }

    private func dispatch(_ item: QueuedReply, to session: AgentSession, host: RemoteHost?) {
        sending.insert(item.chatID)
        var marked = queue
        marked.markDispatched(chatID: item.chatID, at: Date())
        commit(marked)
        let request = item.request, stops = ReplyQueue.continuesIdleBackground(session)
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result { try ChatReply.send(request, to: session, host: host, stopIdleBackground: stops) }
            }.value
            sending.remove(item.chatID)
            switch result {
            case .success: finish(item, sent: true, message: "Queued message sent.")
            case .failure(let error) where ReplyQueue.retries(after: error):
                // Working or waiting after all: nothing went; try again when it is next idle.
                var next = queue
                next.requeue(chatID: item.chatID, now: Date())
                idleSince[item.chatID] = nil
                commit(next)
            case .failure(let error) where SendOutcome.isUnconfirmed(error):
                // It may have gone: never retried, and never reported as "not sent".
                finish(item, sent: false, message: "Queued message: " + ((error as? LocalizedError)?.errorDescription ?? "Burro couldn't confirm it went."))
            case .failure(let error):
                finish(item, sent: false, message: "Queued message not sent: " + ((error as? LocalizedError)?.errorDescription ?? "it couldn't be delivered."))
            }
        }
    }

    private func finish(_ item: QueuedReply, sent: Bool, message: String) {
        var next = queue
        next.cancel(chatID: item.chatID)
        next.record(ReplyQueueNotice(chatID: item.chatID, text: item.text, sent: sent, message: message, at: Date()), now: Date())
        missingSince[item.chatID] = nil; idleSince[item.chatID] = nil
        commit(next)
    }

    private func commit(_ next: ReplyQueue) {
        queue = next
        try? store.save(next)
    }
}
