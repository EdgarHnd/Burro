# Changelog

## Unreleased

- Lead Home with what needs you: under the greeting, amber rows for chats waiting on you (up to five, then **Show all N in Chats**) and one quieter line for results to read, or "Nothing needs you". The cover's chips split into running, **need you** (amber) and **to read**, shown only when there is something, and all open Chats; the plain-language summary moves onto the cover. Project, machine and note cards are flat and monochrome, with colour only in their live counts. The Chat / Project / Machine quick actions, the inbox card and the dock's machines are gone; the dock's avatars are grouped into running, needs you and to read.
- Add a ⌘K command palette to the main window (**View ▸ Command Palette…**): type to jump to any page, chat on any machine, project or machine, or to open New chat (also in a given project), open Settings, refresh the page, keep the Mac awake for 2 hours (or stop), or put a question about a chat in the Orchestrator's composer. Chats that need you rank first. Nothing in it sends a message or starts an agent by itself; the Notes window keeps its own ⌘K.
- Tidy the window's top bar: Home, Orchestrator and Today come first, in ⌘1–⌘3 order, and the current page's icon widens into a pill with its name instead of a breadcrumb. Go **Back** and **Forward** between pages with ⌘[ and ⌘] (Go menu); after a jump from inside a page (a chat opened from Today, say), a back pill returns to where it started. The Chats badge is amber while a chat needs you and blue when there are only results to read, uncertain chats are grey rather than amber, and secondary text has more contrast. **Window ▸ Burro** (⌘0) reopens the window after you close it.
- Show at a glance from the menu bar when a chat needs you: the item is the Burro icon alone when idle, the icon and a count while agents run, and a needs-you glyph with the number waiting. Its menu lists up to five chats waiting on you (choosing one opens it like a notch row), and **Open Today** and **Open Chats** replace Open Usage and Open Mac Health. The compact notch leaves a side empty while its count is zero.
- Quieten the Today page: the date sits on the page with the time to the minute; the row of stat tiles becomes one headline (focused of tracked time, or the time with agents when tracking is off) and one line of facts that leaves out anything with nothing to say; amber marks only questions waiting on you. On a short day the timeline sizes to its content with Your day as one row beneath it. Shipped always shows the page's day, with the recap of the days before under it; the Today | Yesterday switch is gone.
- Show when Burro wasn't recording: the tracker keeps a small `.coverage` file per day saying when it was recording, so time Burro was closed or paused shows as its own **Not recording** divider on the timeline, distinct from **Idle** (you were away), and the facts line says "Not recorded 0:00–16:42" (or "Not recorded for 5h 20m" for several gaps). Days recorded before this, and imported days, make no such claim. Choose how long without input counts as away (**Away after** 2, 5 or 10 minutes in the Activity **⋯** menu).
- Have the Orchestrator draft replies and new chats instead of starting chats itself: a new `reply_chat` tool and the changed `start_chat` only record a proposal, shown as a card under its answer where you edit the text, then **Send** or **Discard**. Nothing goes out until you click Send, which uses the same path as the Chats composer or New chat; a card warns when the chat has stopped waiting. Proposals are kept in `actions.json` in the Orchestrator's folder and expire after a day, and Home's Orchestrator card says when some wait for you. Pick its model next to the effort menu (Fable 5.2 by default).
- Open quietly at login: a login-item launch starts the notch, menu bar and activity tracking without activating Burro or showing the window, and a Dock click (or opening Burro again) always brings the window back. Add Fable 5.2 to the Claude models in New chat and the Chats composer (and its reference rate to local cost estimates), and Settings switches for reading the site in Arc and Chromium browsers and for Claude-written Shipped summaries.
- Add optional notifications (Settings › Notifications, off by default): one banner when a chat on any machine has been waiting on you for a few seconds, and optionally when one finishes, withdrawn once it stops waiting or the result is read. Clicking it opens the chat. Chats already waiting when Burro first sees them (at launch, or when a machine connects or reconnects) and subagents don't notify, and leftover banners from a previous run are cleared.
- Show Claude's Done badges again: its unread store is read correctly when a record sits at the edge of a log block. Claude's and Codex's unread state, or a failure to read it, is reused while their files are unchanged, and a read-state problem is still reported but no longer keeps agent checks at every 3 seconds, so quiet agents relax to every 15 seconds.
- Check remote Macs every 10 seconds only while the window is on screen, the notch is open, or a remote chat is working or waiting on you, and otherwise once a minute; a sample now stays fresh for 90 seconds. Back off from an unreachable Mac (15, 30, 60, then 120 seconds) until it answers, you refresh, or you edit it. Every SSH call to a Mac (probes, transcripts, replies, machine checks) shares one connection, closed 2 minutes after its last use. Pages redraw only when a chat they show changed.
- Add Open at login (Settings → Startup, and **Open Burro at login** in the Today page's activity **⋯** menu): Burro registers itself as a login item so activity tracking and the notch start with your Mac instead of when you first open it. Off until you turn it on; the switch always shows what macOS says, rereads it when Burro comes back to the front (so a change in System Settings › General › Login Items shows up), offers **Open Login Items…** when macOS wants your approval, and says so when adding or removing fails.
- Keep activity tracking honest when you step away: the Today page moves on to the new day at midnight instead of staying on yesterday (a past day you picked stays put); only your own input ends idle time, so apps an agent brings to the front while you're away are no longer counted as you; a return from idle is noticed within seconds; time recorded after the moment you went idle is trimmed; and the unlock prompt's helper and zero-length blips are no longer recorded.
- Add Keep awake (Mac Health, menu bar and Settings): keep this Mac awake for 1, 2 or 4 hours or until you stop, or while agents work on this Mac plus a few minutes. An open lid uses an idle-sleep assertion; a closed lid uses `pmset -a disablesleep 1` like NoSleepBar, through a one-time sudoers rule for exactly that flag or an administrator prompt. A shell watchdog turns sleep back on when you stop, when the agents are done, 30 seconds after Burro quits (a relaunch takes the session over), after 15 minutes without word from Burro, or at 10% battery. Sleep left off with no session is reported, and Burro's own leftover is undone. Mac Health never lists the watchdog as a leftover.
- Reorganise the Today page so it reads top to bottom, full width: one summary row of compact tiles (Focused, Tracked, Break, Longest focus, Messages, To-dos, Questions) replaces the tall side cards; tracked focus is the headline and the first-to-last-message span becomes a named fact in the hours strip ("Chatting with agents 0:07 – 12:16"), or the first tile when tracking is off. The timeline sits beside one Your day so far card (categories, most time, focus stretches, what Break went to) at a matching height; Shipped and Chats follow. Cards size to their content.
- Make the activity timeline quieter: it starts at the first block's hour and ends at the last block or now, idle gaps over 45 minutes become a thin "Idle · 2h 10m" divider, the lock screen and login window are no longer recorded or shown, blocks and rows under a minute are hidden, runs under 5 minutes fold into neighbours, short alternating runs become one "Switching between Claude and Arc" block, and titles never repeat the app.
- Read the site in Arc (and in Chrome, Brave or Edge when their address field can't be found): Burro asks the browser once per launch to build its accessibility tree and reads only the page address of the window's web area, keeping the host.

- Add a one-time Dayflow import to `burro-inspect` (`--activity-import-dayflow [--dry-run] [--database <path>] [--activity-dir <path>]`): each Dayflow card becomes one timeline block with its own title and mapped category, after the live privacy rules (Personal, banking sites and credential apps become Private), without touching days' live-tracked time and replacing its own earlier import when re-run. Keep tracked activity for 365 days instead of 30.
- Replace the Dayflow integration with Burro's own on-device activity tracker on the Today page. Off by default; it records the frontmost app, its window title (with Accessibility) and a browser's host only, never the screen, and keeps it in owner-only daily files for 365 days. Password managers, private windows and banking sites keep no title, and every title is clipped and scrubbed of long numbers, IBANs and email addresses. Rule-based categories you can change per app or site, pause, delete a day or everything. Event-driven sampling with a slow idle check and coalesced writes.
- Add a day view for tracked activity on the Today page: a timeline of readable blocks (one category with short gaps, sub-2-minute runs folded in, titled by the main app and its site or window title, or "Switching between…"; idle time left empty) with app icons, plus Your day so far (category donut and most-used apps and sites), Your focus (focused time and the longest focus stretch) and Break so far, beside the timeline on wide windows and below it on narrow ones. Add a Today so far card to Home while tracking is on (focused and tracked time, what you're on now, Break and the longest focus stretch; click to open Today), read once a minute while Home is on screen.

## 0.6.19 — Unreleased

- Move local token-history scanning for Codex, Claude and Grok into a separately supervised Rust worker with bounded counter caches and Swift recovery. Prioritize recent logs and clearly label partial totals.
- Cache Claude desktop completion metadata in Rust, reading only completion fields instead of rebuilding large nested JSON objects on every refresh.
- Share Codex lifecycle events, age thresholds and Claude status aliases across local and remote adapters. Treat future timestamps conservatively.
- Wake local monitoring on file changes, combine bursts, retain frequent active/uncertain process checks, and use a slower fallback when quiet. Add local CPU, memory and scan profiling tools.

## 0.6.18 — Unreleased

- Add Today's chats to the notch options, showing local and connected-Mac chats active today in last-active order, including idle and closed chats. Keep rows compact, show activity times, retain the selected view across Usage previews, and preserve stable targets while interacting.

## 0.6.17 — Unreleased

- Fix skipped layouts after repeatedly hovering Usage and returning to Agents. Defer and combine content resize requests until SwiftUI finishes rendering, avoid unchanged geometry updates, and cancel pending requests when the notch stops.

## 0.6.16 — Unreleased

- Fix cropped layouts when hovering the Usage tab: update an open panel's content size and clipping outline together, keeping tabs anchored and restoring the original Agents size on exit. Preserve animated notch opening/closing and click-to-commit behavior.

## 0.6.15 — Unreleased

- Let the butter hop off its stationary wrapper, squash on landing, double bounce, tilt, glance, and blink. Use orange Claude and blue Codex butter avatars across notch sessions, remote sessions, and agent details, with staggered motion and quieter idle behavior. Preserve compact frames and Reduce Motion support.

## 0.6.14 — Unreleased

- Animate the white butter mascot in the expanded notch with an occasional blink and a gentle bob while agents are working. Preserve its compact size, pause when collapsed or hidden, and honor Reduce Motion.

## 0.6.13 — Unreleased

- Replace the butter emoji with an original minimal white butter mascot in the notch, menu bar, and app icon. Keep compact sizing, use crisp vector artwork, and retain an abstract alternate with transparent PNG/SVG exports.

## 0.6.12 — Unreleased

- Move local Claude delegated-worker discovery and lifecycle parsing into the Rust worker, with bounded scans, cached summaries, and Swift recovery. Fix idle Claude chats incorrectly becoming Unknown after the project history exceeds 256 folders.
- Keep unverified chats in Monitoring details with a visible count, while the active queue focuses on confirmed activity. Preserve their cleanup protection and offer an explicit option to include them in the queue.

## 0.6.11 — Unreleased

- Give the expanded notch a native Liquid Glass surface on macOS 26, with frosted material on earlier macOS versions. Keep the camera area and collapsed notch black, preserve compact dimensions and pointer behavior, and honor Reduce Transparency.

## 0.6.10 — Unreleased

- Unify the entire app with compact charcoal surfaces, rounded controls, consistent provider badges, and shared status colors. Apply the treatment to the sidebar, worktrees, inspectors, remote sessions, settings, cleanup sheets, and both notch pages. Reduce oversized Usage typography, controls, and padding while keeping existing window and notch dimensions.

## 0.6.9 — Unreleased

- Refresh both Usage surfaces with soft charcoal cards, pill controls, stronger numeric typography, and green-to-lime quota accents. Keep the existing dashboard layout, compact notch dimensions, and provider controls.

## 0.6.8 — Unreleased

- Add a bundled Rust worker for local Codex lifecycle-log parsing. Reuse summaries for unchanged files, retain Swift/AppKit UI and live safety checks, and recover through the Swift reader if the worker exits, times out, or returns an invalid response.

## 0.6.6 — Unreleased

- Recognize Claude subagents that finish through a `SubagentHandback` tool-result envelope. Completed workers no longer leave idle parents stuck at Unknown; apply the same lifecycle rule locally and over SSH while retaining live background-task and uncertainty checks.

## 0.6.5 — Unreleased

- Block background Claude password prompts in both macOS Keychain implementations. Serialize and restore the legacy interaction policy; only the first read of an explicit connection may prompt, and retries stay silent.
- Keep saved signing identities and designated requirements stable across updates. Refuse silent fallback or identity changes, and validate replacement bundles before touching the previous app.

## 0.6.4 — Unreleased

- Add a steady amber/blue attention glow to the collapsed notch for input requests and unread completions, including remote sessions and while Usage is selected. Respect Reduce Motion and clear with provider status.
- Allow the notch overlay to join other applications’ fullscreen Spaces without taking focus.

## 0.6.3 — Unreleased

- Add native worktree multi-selection, Select ready, one batch confirmation, and keyboard/context-menu cleanup actions.
- Hide queued rows immediately while preserving per-item safety rechecks. Show nonmodal progress, stop remaining work, restore failed/skipped rows, and retain recovery details without success alerts.
- Discard pre-cleanup background scans so older results cannot bring removed rows back.

## 0.6.2 — Unreleased

- Replace generic cleanup Keep/Review labels with Ready to remove, Local changes, In use, and specific blockers. Use one decision for filters, counts, rows and confirmation.
- Separate removing a checkout from merging its code. Verify a retained local branch contains HEAD, preserve ignored data in Trash, and recheck retention before unregistering. Detached commits without a retaining branch remain blocked.
- Recognize inclusion in staging independently of the selected base and bounded patch equivalence for squash merges. Expose exact changed filenames and the retaining branch in the inspector and confirmation.

## 0.6.1 — Unreleased

- Selectively adopt machine/worktree grouping from DantesHub’s PR #1, with explicit folder/branch labels and local checkout Git delivery. Preserve active chats without edits, unread Done semantics, hover behavior, and Usage tabs.
- Add Cleanup review, primary blockers, correct repository totals, an inspector comparison-branch picker, and confirmed recoverable Move to Trash. Recheck Git/activity/protection; keep branches and ignored data; route managed worktrees through Codex archive. No automatic fetch, forced removal, or branch deletion.

## 0.6.0 — Unreleased

- Recover expired Grok credentials silently through its official CLI, delegate Codex recovery to its app server, and retry Claude reads when Claude Code rotates the credential. Coalesce renewal attempts and retry temporary failures independently without background Keychain dialogs or repeated login prompts.
- Reuse a local Apple Development signing identity across builds to preserve Keychain trust; retain ad-hoc fallback for source-only/CI builds. Document the one-time approval when moving from an ad-hoc build and Claude Code’s ownership of session renewal.

- Add persistent Agents/Usage notch tabs: hover for a temporary preview, click to keep a page selected across collapse/reopen. Reuse native pointer observation and timed entry/exit grace to avoid accidental switching.

- Add a desktop Usage dashboard for Codex, Claude, and Grok: verified account/plan labels, provider tabs, profile selection, official sign-in controls, limits, model quotas, resets, linear pace markers, extra usage, and service/dashboard links.
- Read Claude's current native limits list, including Fable weekly. Show the actual Claude Code account rather than leaving different-account totals unexplained.
- Keep the notch compact with one row per quota and account details on hover; route its dashboard button directly to Usage.
- Add private account-scoped quota history and on-demand local token history, with deduplication, model breakdowns, and explicitly labeled reference API estimates. Unknown prices and incomplete scan coverage remain visible.
- Add provider toggles, refresh cadence, remaining/used display, pace/model controls, and local history retention/deletion. No CodexBar runtime dependency.

## 0.5.0 — Unreleased

- Add a compact standalone Usage view for Codex and Claude limits, remaining bars, and reset countdowns. Fetch directly through Codex’s app server and Claude Code’s existing sign-in; no CodexBar dependency. Include native Claude connection permission, manual refresh, per-provider errors, account-wide scope, and stale/expired data handling. Keep credentials in memory and never send prompts or model requests.

## 0.4.2 — Unreleased

- Detect local Claude background commands and subagents even while their parent reports idle.
- Show local and remote delayed background commands as Scheduled with a teal clock. Keep them visible without inflating Running or Needs you counts, preserve permission requests, and suppress Done until delegated work ends. Explicit live sleep tasks qualify; ordinary sleeping processes do not.

## 0.4.1 — Unreleased

- Keep remote Claude chats active while their subagents or session-owned background commands are still running, even when the parent registry reports idle. Preserve permission requests, reject old/completed worker evidence, and suppress unread Done until work finishes.

## 0.4.0 — 2026-09-28

First public source release.

- Native worktree inventory with conservative Keep, Review, and Safe candidate assessments.
- Codex and Claude Code monitoring, unread completion tracking, worker grouping, and provider chat navigation.
- Minimal hover-driven notch with stable rows during interaction and Reduce Motion support.
- Explicit SSH monitoring for other laptops and servers, with last-seen states on connection failure.
- Dark butter app icon generated locally and applied at launch.
- MIT license, contribution/security guidance, synthetic fixtures, and macOS/Linux CI.

This is an early-stage source release. There are no prebuilt notarized binaries, automatic updates, or worktree deletion actions.
