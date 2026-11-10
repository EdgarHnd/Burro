# 🧈 Burro

**A quiet home for your coding agents and Git worktrees.**

[![CI](https://github.com/EdgarHnd/Burro/actions/workflows/ci.yml/badge.svg)](https://github.com/EdgarHnd/Burro/actions/workflows/ci.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#build-and-run)

Burro is a small native macOS app that shows what Codex and Claude Code are doing, which worktrees they use, and which folders need a closer look before cleanup. A minimal notch panel keeps running agents and unread results in view without opening another dashboard.

Early-stage software. Provider metadata formats are private and may change; Burro shows incomplete visibility rather than treating missing evidence as safety.

## What it does

- **Home:** an ASCII aquarium behind the page where your agents are the fish (species from provider and model, fins and markings from effort, size from age, amber at the surface when one needs you, jellyfish for scheduled chats, and the rest of today's chats swimming darker; click one to open its chat), or a glyph, pixel or photo cover, with live counts, quick actions, your projects and machines as cards, a plain-language summary, to-dos, notes, a scratchpad, an inbox of chats waiting on you, and a dock of live agents and machines. Click anything to open the chat or the page behind it. Light, dark or match the system. An icon top bar (Today, Home, inbox, worktrees, machines, usage, health, New chat) shows badges for what needs you.
- **Main project:** Home features one project (the repository with the most worktrees, or the one you pick from its **⋯** menu): what's live in it on every machine, its other chats today, worktree and token counts, and one click to start a chat there.
- **Orchestrator (⌘2):** one Claude Code chat (Fable 5.2, High effort) that Burro runs for you, with its own page (the conversation, plus a live panel of the agents it watches and their subagents) and a card on Home. Through Burro's own tools it sees every chat and subagent on every machine, your projects, worktrees, machines and to-dos; it reads any chat when it needs detail and starts Codex or Claude chats on this Mac when you ask. It can read and search files but can't edit them or run commands.
- **Chats (⌘4):** every Codex and Claude chat on every machine in one list (Needs you, Working, Ready to read, Recent), laid out like the agents' own apps: a long brief as a Task card, each turn's work under "Worked for 3m 9s" with tool runs folded ("Ran 5 commands, read 2 files"), the plan as a checklist and a live line for what it's doing now, a details panel (folder, model and effort, context, changes, running subagents), and the reply with Markdown, code, and the images and videos the agent made (copied over SSH from other machines). Reply from the composer with the same choices the apps give you: access (including Codex's Approve for me), model and effort. Chats that are working refresh while you watch.
- **Benches:** group projects into your own benches (Work, Homelab, Personal…) with an icon and colour. Home shows each bench's combined live counts; clicking one filters the worktree list to it.
- **Machines (⌘6):** this Mac, your SSH machines and every device on your Tailscale network, with OS, presence, running agents and project folders, plus a table of agent tools (Claude Code, Codex, opencode, Grok, Cursor, Gemini) per machine with the latest release and a confirmed **Update** that runs the tool's own updater.
- **Today page (⌘3):** one day at a glance: what shipped on GitHub for the main project (pull requests merged into staging, production releases and pushes, yours and your teammates', in one plain sentence plus per-person lists, with yesterday's recap a click away), chats grouped by status or project with the first line of their latest reply, how long you've been at it with an hourly bar, messages sent vs replies, to-dos, questions agents asked you, and, if you turn it on, Burro's own on-device activity tracker (frontmost app, window title and a browser's host; never the screen) with time per category and top apps and sites. Step back through earlier days.
- **Notes (⌥P):** a floating notes window from any app, in the spirit of Raycast Notes. Checklists you tick in place, ⌘P to browse and search notes (pinned first), ⌘K for actions: new, duplicate, pin, back and forward, find, copy as Markdown or plain text, send the note to the Orchestrator, or turn its open checklist items into to-dos. The same notes are listed on Home.
- **Today card:** a minimal to-do list for the day on Home. Tick, type to add, double-click to edit; unfinished items roll over. Syncs with Maurice's Convex backend (so the Maurice app can show it) or stays on this Mac until you connect.
- **New chat (⌘N):** start a Codex or Claude Code chat in any project: pick the model, effort and access level, and Burro starts it (Codex in its own background daemon, Claude as a background session). It shows up in Home and the notch like any other chat; Codex chats open in the Codex app, Claude sessions can attach in Terminal.
- **Agent notch:** hover to expand, pin when needed, and see needs-input, unread Done, and running chats in that order. Background workers stay grouped under their parent when the relationship is known.
- **Usage dashboard:** compact notch quotas and full desktop controls for Codex, Claude, and Grok. See account/plan labels, model limits (including Fable), resets, pace, history, and local token/cost estimates. Connect directly using coding-app sign-ins; no CodexBar dependency.
- **Mac Health:** CPU, memory pressure, swap, and disk in the notch and a desktop page, plus processes and simulators left running after their work ended (stuck scripts, idle dev servers, orphaned watchers). Stopping one always asks first.
- **Open the conversation:** click a chat to open it in Codex or Claude when the provider exposes a usable link.
- **One view across machines:** add another laptop or server through your existing SSH connection. Disconnected machines show their last-seen state.
- **Worktree inventory:** find registered, detached, inactive, locked, and missing worktrees; inspect branches, changes, processes, and agent activity.
- **Actionable cleanup:** Ready to remove, Local changes, In use, or a specific blocker. Code integration is shown separately from checkout removal. Multi-select or Select ready, confirm once, and keep browsing while folders move to Trash. Per-item rechecks preserve contents and keep commits on a verified local branch; failed items return with a reason.
- **Local by default:** no Burro account, analytics service, or provider hooks. Native SwiftUI and AppKit with a Rust metadata and session-log workers, SQLite, Git, and OpenSSH.

Background monitoring is read-only: Burro never starts or messages an agent on its own. Chats start only from **Start chat** or when you ask the orchestrator, and a message reaches an existing chat only when you press **Send**; **Move to Trash** is an explicit action. **Move to Trash** is an explicit, confirmed action that rechecks Git and activity, preserves the whole checkout in Trash, unregisters only that worktree, and retains its branch. Codex-managed worktrees use Codex’s archive flow. Readiness is a point-in-time observation, not a guarantee. Burro does not automatically fetch Git refs or mark chats read. See [cleanup and recovery](docs/usage.md#cleanup-and-recovery).

## Build and run

Requirements: **macOS 14 or later**, **Swift 6** (Xcode 16+ or compatible Command Line Tools), **Rust via [rustup](https://rustup.rs/)**, and Git. Check `swift --version` first. `rust-toolchain.toml` pins Rust 1.98.0 (older toolchains build proc-macros that macOS 27 refuses to load); Cargo dependencies are locked. Python 3 is needed for probe tests and on each remote host. The app bundles its Rust executable; users and remote hosts do not need Rust installed.

```sh
git clone https://github.com/EdgarHnd/Burro.git
cd Burro
./script/build_and_run.sh
```

This builds and launches `dist/Burro.app`. Copy it to your Applications folder if you want to keep it. The build generates the dark butter icon from the included original vector mascot. Xcode 26+ builds enable Liquid Glass on macOS 26; older toolchains and systems use the native frosted material.

Parent-owned Rust workers index Codex session metadata and process Codex lifecycle logs, Claude delegated-worker logs and desktop completion metadata, and on-demand token history for Codex, Claude and Grok. Unchanged files reuse bounded caches of lifecycle summaries or token counters; conversation text is never cached. The read-only metadata index keeps a SQLite connection, checks commits from other connections, and sends a new snapshot only when relevant rows change; replacements, read failures, and worker restarts cannot reuse stale rows. History runs in a separate child so it cannot block live agent status. Swift retains the native UI, live lock/process checks, provider connections, pricing and cleanup policy. Failed or timed-out workers recover through Swift readers and can restart after a cooldown. There is no network listener, login item or background service. Burro remains a hybrid Swift/Rust app.

Local monitoring wakes on relevant provider filesystem changes (ignoring unrelated Codex logs/build output), coalesces bursts and checks active or uncertain sessions every three seconds after scans. Quiet monitoring falls back to fifteen seconds; missing watcher support retains three-second checks. Remote monitoring continues every ten seconds. Shared lifecycle mappings and freshness thresholds live in `policy/session-status.json`; generated Swift/Rust/Python adapters and shared fixtures prevent drift.

The live Codex view reads today's and recently active chats, plus writer-lock, unread and pinned chats and their parents. Worktree inventories and cleanup checks read the complete catalog. Lock filenames are indexed for one refresh; existing locks are checked live, and directory changes fall back to complete per-file checks.

Git refreshes when the worktree dashboard opens or you switch back to a worktree view, if its snapshot is at least 30 seconds old. Repositories are not polled on a timer; live agent monitoring continues independently. Scans reuse unchanged worktree facts, invalidating them on checkout/shared-Git/configuration filesystem changes, watcher overflow, HEAD/base changes, or a fifteen-minute maximum age. Failed watchers and incomplete facts do not cache. Manual refresh and cleanup preflight always inspect fresh state. Claude unread preferences are cached only while all database file identities and modification stamps remain unchanged. Active Codex catalog updates transfer changed chat records instead of resending historical titles.

Daily use: build optimized (`CONFIGURATION=release ./script/build_and_run.sh`). Debug builds are noticeably slower to draw and scroll.

For an optimized local build without launching:

```sh
CONFIGURATION=release ./script/build_and_run.sh --build-only
```

This release is **source-only**. Local builds preserve their selected Apple Development signing identity and refuse silent changes that would invalidate Keychain access. Fresh source builds without a certificate use ad-hoc signing. Set `BURRO_SIGNING_IDENTITY` to select an identity (`-` forces ad-hoc). Builds are not Developer ID signed or notarized; there is no prebuilt download or automatic updater. The build targets the architecture of the Mac that runs it.

## First run

1. Open Burro. It discovers repositories from `~/Dev`, Codex worktrees, and available agent metadata. Use **Add repository** for other folders.
2. Hover over the black strip at the top of your screen. Click a chat to open it, or use the pin to keep the panel visible. Choose **Today's chats** from the notch's **⋯** menu to browse chats active today, newest first, including idle and closed chats. Use **Active chats** to return to the attention queue. A camera notch is optional.
3. To monitor another machine, first verify your SSH connection in Terminal, then choose **Settings → Add remote machine…** (or **Add over SSH** on a Tailscale device in Machines). Burro uses your existing SSH configuration and verified host keys.

See the [usage guide](docs/usage.md) for status meanings, provider compatibility, unread tracking, remote setup, and keyboard shortcuts.

## Privacy and limitations

Burro reads local Git state, same-user process metadata, and provider session files. Chat titles and paths are shown in memory; configuration and protections are saved in macOS preferences. Transcript tails are inspected for lifecycle events, but message bodies are not retained or exported. The Today page counts messages per hour and, unless you turn previews off, shows the first line of each chat's latest reply; that line is read on demand, held in memory and never cached or saved. The optional activity tracker (off by default) records the frontmost app, its window title and a browser's host to owner-only files in `~/Library/Application Support/Burro/Activity` (30 days), after removing titles for password managers, private windows and banking sites and scrubbing numbers and emails from all titles; it never records the screen and never sends or shares that data. The Today page's **Shipped** section reads the main project's GitHub repository through the GitHub CLI's existing sign-in (read-only `gh api` calls: merged pull requests, repository activity, manual workflow runs, Production deployments) and keeps the result in memory only. **Chats** reads a chat's latest messages on demand (at most 300, from the last 16 MiB of its file; over SSH for other machines) and holds them in memory only; images and videos linked in replies are read in place on this Mac, or copied once per run into `~/Library/Caches/Burro/Media` (cleared at launch) from other machines. The **orchestrator** is an ordinary Claude Code conversation: what it reads (Burro's snapshot, chats it opens, files it reads) is sent to Anthropic as part of that conversation, and Claude Code saves its transcript under `~/.claude/projects` as usual. Burro's snapshot for it (chat titles, paths, machine names, worktree facts and to-dos; no message bodies or credentials) is written to `~/Library/Application Support/Burro/Orchestrator/state.json` (owner-only) when you ask it something. The optional Usage dashboard asks the installed Codex app server for limits and reads selected Claude/Grok coding-app sign-ins in memory for fixed provider usage endpoints. Account-scoped quota history is stored locally; an on-demand scanner reads local token counters without retaining message text. It does not copy provider credentials to disk or import browser cookies (the only secret Burro stores is the Convex token you import for to-do sync, in your Keychain); direct background Keychain reads never prompt, and Claude can supply quotas through its own bounded zero-turn CLI command when its Keychain grant resets. See the [usage guide](docs/usage.md#usage-limits) for setup and access details.

Remote monitoring sends a fixed inspection script to hosts you explicitly add and returns session metadata over SSH. It does not inherit Codex/Claude desktop pairings or monitor cloud-hosted tasks. The dashboard's cleanup advice covers local worktrees only.

CLI output and screenshots can contain private titles and filesystem paths. Review and redact them before sharing. See [SECURITY.md](SECURITY.md) for the trust model and private vulnerability reporting.

## Develop and contribute

```sh
cargo test --manifest-path Rust/Cargo.toml --target-dir .build/rust --locked
./script/build_rust_worker.sh
BURRO_REQUIRE_RUST_WORKER=1 swift test
python3 -B script/test_remote_probe.py
./script/build_and_run.sh --build-only
```

Plain `swift test` remains available without Rust; the worker integration tests report skips if the helper is missing. CI requires them. An opt-in release benchmark compares repeated synthetic log scans: `BURRO_REQUIRE_RUST_WORKER=1 BURRO_WORKER_BENCHMARK=1 swift test -c release --filter AgentLogWorkerTests.testSyntheticWarmScanBenchmark`. It does not measure whole-app CPU, battery use, or UI performance.

The AppKit panel tests require an active macOS graphical session. CI runs the other Swift tests and builds the app; the remote probe fixtures also run on Linux. See [CONTRIBUTING.md](CONTRIBUTING.md) and [architecture](MODULE.md).

A JSON CLI is included:

```sh
swift run burro-inspect --agents
swift run burro-inspect /path/to/repository
```

[Report a bug](https://github.com/EdgarHnd/Burro/issues/new/choose) · [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE). Codex, Claude, and macOS belong to their respective owners. Burro is an independent project and is not affiliated with OpenAI, Anthropic, or Apple. The repository includes original vector mascot assets and reproducible icon-generation code.

### Local performance measurements

After building, run `swift build -c release --product burro-inspect`, then `./script/build_rust_worker.sh "$(swift build -c release --show-bin-path)"`. The helper must sit beside the release inspector to measure Rust instead of recovery readers.

- `.build/release/burro-inspect --profile-git` compares one cold and two incremental read-only worktree scans.
- `.build/release/burro-inspect --profile-agents` measures process, unread-state and complete local-agent refreshes.
- `.build/release/burro-inspect --profile` also measures cold/warm on-demand token history.
- `python3 -B script/profile_runtime.py --executable "$PWD/dist/Burro.app/Contents/MacOS/Burro" --seconds 30` samples the running app and observed child processes.
- `BURRO_REQUIRE_RUST_WORKER=1 BURRO_WORKER_BENCHMARK=1 swift test -c release --filter UsageLogWorkerTests.testSyntheticHistoryBenchmark` compares equal-coverage synthetic usage scans.

Output contains counts and timings, not chat text or paths. Inspector CPU/memory covers the parent; wall time includes the worker. The runtime profiler reports both sampled CPU (which misses short-lived helpers) and macOS kernel CPU/wakeup counters including reaped children. Process-tree snapshots can race with helper exits; use multiple intervals under matching visibility and workload, and measure initial/visible Git scans separately from hidden-dashboard monitoring. CPU, wakeups and summed memory are not battery consumption. Real token history can be partial under the existing file/time limits; compare identical complete fixtures before claiming parser speedups.
