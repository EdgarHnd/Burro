import XCTest
@testable import BurroCore

final class ChatAlertsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private func waiting(_ id: String) -> ChatAlertSample { ChatAlertSample(id: id, waiting: true) }
    private func working(_ id: String) -> ChatAlertSample { ChatAlertSample(id: id, working: true) }
    private func idle(_ id: String) -> ChatAlertSample { ChatAlertSample(id: id) }
    private func done(_ id: String) -> ChatAlertSample { ChatAlertSample(id: id, done: true) }

    /// A tracker with `ids` already seen working.
    private func running(_ ids: String...) -> ChatAlertTracker {
        var tracker = ChatAlertTracker(settle: 5, absenceGrace: 60, forgetAfter: 86_400)
        _ = tracker.update(ids.map(working), at: at(0))
        _ = tracker.update(ids.map(working), at: at(40))
        return tracker
    }

    func testANewWaitingChatPostsOnceAfterItSettles() {
        var tracker = running("a")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(43)), [], "one sample isn't enough")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(46)), [], "3 s is still under the settle time")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(49)), [.post(.needsYou, chat: "a")])
        for second in stride(from: 52.0, through: 100, by: 3) {
            XCTAssertEqual(tracker.update([waiting("a")], at: at(second)), [], "one notification per episode")
        }
    }

    func testAFlickerIntoWaitingPostsNothing() {
        var tracker = running("a")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(43)), [])
        XCTAssertEqual(tracker.update([working("a")], at: at(46)), [])
        XCTAssertEqual(tracker.update([waiting("a")], at: at(49)), [], "the run starts over")
        XCTAssertEqual(tracker.update([working("a")], at: at(52)), [])
    }

    func testAShortDipOutOfWaitingDoesntPostAgain() {
        var tracker = running("a")
        _ = tracker.update([waiting("a")], at: at(43))
        XCTAssertEqual(tracker.update([waiting("a")], at: at(49)), [.post(.needsYou, chat: "a")])
        XCTAssertEqual(tracker.update([working("a")], at: at(52)), [], "a single sample out doesn't end the episode")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(55)), [])
        XCTAssertEqual(tracker.update([waiting("a")], at: at(70)), [])
    }

    func testLeavingWaitingWithdrawsTheNotificationAndAllowsTheNextEpisode() {
        var tracker = running("a")
        _ = tracker.update([waiting("a")], at: at(43))
        _ = tracker.update([waiting("a")], at: at(49))
        XCTAssertEqual(tracker.update([working("a")], at: at(52)), [])
        XCTAssertEqual(tracker.update([working("a")], at: at(57)), [.withdraw(.needsYou, chat: "a")])
        XCTAssertEqual(tracker.update([waiting("a")], at: at(60)), [])
        XCTAssertEqual(tracker.update([waiting("a")], at: at(66)), [.post(.needsYou, chat: "a")], "a new question is a new episode")
    }

    func testChatsAlreadyWaitingAtLaunchPostNothingUntilTheyComeBack() {
        var tracker = ChatAlertTracker(settle: 5, absenceGrace: 60, forgetAfter: 86_400)
        XCTAssertEqual(tracker.update([waiting("a")], at: at(0)), [])
        XCTAssertEqual(tracker.update([waiting("a"), waiting("remote")], at: at(12)), [], "a remote machine connecting late counts as launch")
        XCTAssertEqual(tracker.update([waiting("a"), waiting("remote")], at: at(60)), [])
        XCTAssertEqual(tracker.update([working("a"), waiting("remote")], at: at(63)), [])
        XCTAssertEqual(tracker.update([working("a"), waiting("remote")], at: at(69)), [], "nothing was posted, so nothing to withdraw")
        _ = tracker.update([waiting("a"), waiting("remote")], at: at(72))
        XCTAssertEqual(tracker.update([waiting("a"), waiting("remote")], at: at(78)), [.post(.needsYou, chat: "a")])
    }

    func testAChatFirstSeenWaitingAtAnyTimeIsTakenAsItIs() {
        var tracker = running("a")
        // Long after launch: a machine connecting late, or this Mac waking from a long sleep.
        XCTAssertEqual(tracker.update([working("a"), waiting("b"), done("c")], at: at(3_600)), [])
        XCTAssertEqual(tracker.update([working("a"), waiting("b"), done("c")], at: at(3_610)), [], "already waiting or finished when first seen")
        XCTAssertEqual(tracker.update([working("a"), waiting("b"), done("c")], at: at(4_000)), [])
        // Seen out of waiting, then back: that is a new episode.
        _ = tracker.update([working("a"), working("b"), done("c")], at: at(4_003))
        XCTAssertEqual(tracker.update([working("a"), working("b"), done("c")], at: at(4_009)), [], "nothing was posted, so nothing to withdraw")
        _ = tracker.update([working("a"), waiting("b"), done("c")], at: at(4_012))
        XCTAssertEqual(tracker.update([working("a"), waiting("b"), done("c")], at: at(4_018)), [.post(.needsYou, chat: "b")])
        // A brand-new chat seen idle first, then waiting, notifies like any other.
        _ = tracker.update([idle("d")], at: at(4_021))
        _ = tracker.update([waiting("d")], at: at(4_024))
        XCTAssertEqual(tracker.update([waiting("d")], at: at(4_030)), [.post(.needsYou, chat: "d")])
    }

    func testAStaleChatThatComesBackStillWaitingIsTheSameEpisode() {
        var tracker = running("a", "b")
        _ = tracker.update([waiting("a"), waiting("b")], at: at(43))
        XCTAssertEqual(tracker.update([waiting("a"), waiting("b")], at: at(49)), [.post(.needsYou, chat: "a"), .post(.needsYou, chat: "b")])
        // The host's probe fails: its chats go stale and are reported unavailable, for an hour.
        for second in stride(from: 60.0, through: 3_660, by: 60) {
            XCTAssertEqual(tracker.update([], unavailable: ["a", "b"], at: at(second)), [], "the banner stays while the host is stale")
        }
        // The next good probe: still waiting, no second banner.
        XCTAssertEqual(tracker.update([waiting("a"), waiting("b")], at: at(3_663)), [])
        XCTAssertEqual(tracker.update([waiting("a"), waiting("b")], at: at(3_700)), [])
        // Back but no longer waiting: now the banner goes.
        _ = tracker.update([working("a"), waiting("b")], at: at(3_703))
        XCTAssertEqual(tracker.update([working("a"), waiting("b")], at: at(3_709)), [.withdraw(.needsYou, chat: "a")])
    }

    func testAChatGoneForLongStillDoesntNotifyAgainWhenItReturns() {
        var tracker = running("a")
        _ = tracker.update([waiting("a")], at: at(43))
        _ = tracker.update([waiting("a")], at: at(49))
        // Missing from the samples entirely (not reported stale), for hours: the banner goes after the grace.
        XCTAssertEqual(tracker.update([], at: at(100)), [])
        XCTAssertEqual(tracker.update([], at: at(110)), [.withdraw(.needsYou, chat: "a")])
        XCTAssertEqual(tracker.update([], at: at(7_200)), [])
        XCTAssertEqual(tracker.update([waiting("a")], at: at(7_203)), [], "still the same episode")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(7_300)), [])
        // A finish seen before going missing isn't posted twice either.
        var finish = running("f")
        _ = finish.update([done("f")], at: at(43))
        XCTAssertEqual(finish.update([done("f")], at: at(48)), [.post(.finished, chat: "f")])
        _ = finish.update([], unavailable: ["f"], at: at(5_000))
        XCTAssertEqual(finish.update([done("f")], at: at(5_003)), [])
        XCTAssertEqual(finish.update([done("f")], at: at(5_010)), [])
    }

    func testChatsUnseenForADayAreForgottenAndTheirBannersWithdrawn() {
        var tracker = running("a")
        _ = tracker.update([waiting("a")], at: at(43))
        _ = tracker.update([waiting("a")], at: at(49))
        XCTAssertEqual(tracker.update([], unavailable: ["a"], at: at(80_000)), [], "stale for most of a day: still held")
        XCTAssertEqual(tracker.update([], unavailable: ["a"], at: at(86_449)), [.withdraw(.needsYou, chat: "a")], "unseen for a day")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(86_452)), [], "forgotten, so taken as it is when seen again")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(86_500)), [])
    }

    func testNotificationIdentifiersAreRecognisedByPrefix() {
        XCTAssertEqual(ChatAlertEvent.identifier(.needsYou, chat: "s1"), "chat.needsYou.s1")
        XCTAssertTrue(ChatAlertEvent.isChatAlert("chat.needsYou.s1"))
        XCTAssertTrue(ChatAlertEvent.isChatAlert("chat.finished.remote:abc"))
        XCTAssertFalse(ChatAlertEvent.isChatAlert("chat.needsYou."))
        XCTAssertFalse(ChatAlertEvent.isChatAlert("chat.other.s1"))
        XCTAssertFalse(ChatAlertEvent.isChatAlert("keepAwake.ended"))
    }

    func testEachChatHasItsOwnEpisode() {
        var tracker = running("a", "b")
        _ = tracker.update([waiting("a"), working("b")], at: at(43))
        XCTAssertEqual(tracker.update([waiting("a"), waiting("b")], at: at(49)), [.post(.needsYou, chat: "a")])
        XCTAssertEqual(tracker.update([waiting("a"), waiting("b")], at: at(52)), [])
        XCTAssertEqual(tracker.update([waiting("a"), waiting("b")], at: at(55)), [.post(.needsYou, chat: "b")])
        XCTAssertEqual(tracker.update([waiting("a"), waiting("b"), waiting("a")], at: at(58)), [], "duplicates in a sample count once")
    }

    func testAFinishPostsAfterWorkAndWithdrawsOnceRead() {
        var tracker = running("a")
        XCTAssertEqual(tracker.update([done("a")], at: at(43)), [])
        XCTAssertEqual(tracker.update([done("a")], at: at(48)), [.post(.finished, chat: "a")])
        XCTAssertEqual(tracker.update([done("a")], at: at(60)), [])
        XCTAssertEqual(tracker.update([idle("a")], at: at(63)), [])
        XCTAssertEqual(tracker.update([idle("a")], at: at(68)), [.withdraw(.finished, chat: "a")])
        XCTAssertEqual(tracker.update([done("a")], at: at(71)), [])
        XCTAssertEqual(tracker.update([done("a")], at: at(80)), [], "no new work since the last finish")
    }

    func testChatsDoneAtLaunchOrNeverSeenWorkingDontPostAFinish() {
        var tracker = ChatAlertTracker(settle: 5, absenceGrace: 60, forgetAfter: 86_400)
        _ = tracker.update([done("a"), idle("b")], at: at(0))
        XCTAssertEqual(tracker.update([done("a"), idle("b")], at: at(40)), [])
        _ = tracker.update([done("a"), done("b")], at: at(43))
        XCTAssertEqual(tracker.update([done("a"), done("b")], at: at(50)), [])
    }

    func testAMissingChatKeepsItsStateForAWhileThenIsWithdrawn() {
        var tracker = running("a")
        _ = tracker.update([waiting("a")], at: at(43))
        _ = tracker.update([waiting("a")], at: at(49))
        XCTAssertEqual(tracker.update([], at: at(70)), [], "a remote machine dropping out briefly")
        XCTAssertEqual(tracker.update([waiting("a")], at: at(80)), [], "still the same episode")
        XCTAssertEqual(tracker.update([], at: at(141)), [.withdraw(.needsYou, chat: "a")])
        XCTAssertEqual(tracker.update([], at: at(200)), [], "withdrawn once")
    }

    func testSamplesComeFromYourOwnLiveChatsOnly() {
        var session = AgentSession(id: "s", provider: .claude, title: "Fix it", cwd: "/tmp/app", state: .waiting, updatedAt: t0, pid: nil, evidence: "")
        XCTAssertEqual(ChatAlertSample(session), ChatAlertSample(id: "s", waiting: true))
        XCTAssertTrue(ChatAlertSample.counts(session))
        XCTAssertFalse(ChatAlertSample.unavailable(session))
        session.remote = RemoteOrigin(hostID: UUID(), hostName: "Studio", sampledAt: t0, stale: true)
        XCTAssertFalse(ChatAlertSample.counts(session), "a stale row's state is unknown")
        XCTAssertTrue(ChatAlertSample.unavailable(session), "but the chat is still known")
        session.isSubagent = true
        XCTAssertFalse(ChatAlertSample.counts(session))
        XCTAssertFalse(ChatAlertSample.unavailable(session))
    }

    func testLaunchKindReadsTheLoginItemOpenEvent() {
        let aevt = LaunchKind.coreEventClass, oapp = LaunchKind.openApplication, lgit = LaunchKind.launchedAsLoginItem
        XCTAssertEqual(aevt, 0x6165_7674)
        XCTAssertEqual(oapp, 0x6F61_7070)
        XCTAssertEqual(lgit, 0x6C67_6974)
        XCTAssertEqual(LaunchKind.propData, 0x7072_6474)
        XCTAssertEqual(LaunchKind.classify(eventClass: aevt, eventID: oapp, propDataEnum: lgit), .loginItem)
        XCTAssertEqual(LaunchKind.classify(eventClass: aevt, eventID: oapp, propDataEnum: nil, hasLoginItemParameter: true), .loginItem)
        XCTAssertEqual(LaunchKind.classify(eventClass: aevt, eventID: oapp, propDataEnum: nil), .normal, "a Dock or Finder launch")
        XCTAssertEqual(LaunchKind.classify(eventClass: aevt, eventID: LaunchKind.fourCharCode("rapp"), propDataEnum: lgit), .normal, "only the open event")
        XCTAssertEqual(LaunchKind.classify(eventClass: nil, eventID: nil, propDataEnum: nil), .normal, "no event at all")
        XCTAssertEqual(LaunchKind.combine(nil, .loginItem), .loginItem)
        XCTAssertEqual(LaunchKind.combine(.normal, nil), .normal)
    }
}
