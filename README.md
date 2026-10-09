# 🧈 Burro

**A quiet home for your coding agents and Git worktrees.**

[![CI](https://github.com/EdgarHnd/Burro/actions/workflows/ci.yml/badge.svg)](https://github.com/EdgarHnd/Burro/actions/workflows/ci.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#build-and-run)

Burro is a small native macOS app that shows what Codex and Claude Code are doing, which worktrees they use, and which folders need a closer look before cleanup. A minimal notch panel keeps running agents and unread results in view without opening another dashboard.

Early-stage software. Provider metadata formats are private and may change; Burro shows incomplete visibility rather than treating missing evidence as safety.

## What it does

- **Agent notch:** hover to expand, pin when needed, and see needs-input, unread Done, and running chats in that order. Background workers stay grouped under their parent when the relationship is known.
- **Usage dashboard:** compact notch quotas and full desktop controls for Codex, Claude, and Grok. See account/plan labels, model limits (including Fable), resets, pace, history, and local token/cost estimates. Connect directly using coding-app sign-ins; no CodexBar dependency.
- **Open the conversation:** click a chat to open it in Codex or Claude when the provider exposes a usable link.
- **One view across machines:** add another laptop or server through your existing SSH connection. Disconnected machines show their last-seen state.
- **Worktree inventory:** find registered, detached, inactive, locked, and missing worktrees; inspect branches, changes, processes, and agent activity.
- **Actionable cleanup:** Ready to remove, Local changes, In use, or a specific blocker. Code integration is shown separately from checkout removal. Multi-select or Select ready, confirm once, and keep browsing while folders move to Trash. Per-item rechecks preserve contents and keep commits on a verified local branch; failed items return with a reason.
- **Local by default:** no Burro account, analytics service, or provider hooks. Native SwiftUI and AppKit with a small Rust session-log worker, system SQLite, Git, and OpenSSH.

Background monitoring is read-only. **Move to Trash** is an explicit, confirmed action that rechecks Git and activity, preserves the whole checkout in Trash, unregisters only that worktree, and retains its branch. Codex-managed worktrees use Codex’s archive flow. Readiness is a point-in-time observation, not a guarantee. Burro does not automatically fetch Git refs or mark chats read. See [cleanup and recovery](docs/usage.md#cleanup-and-recovery).

## Build and run

Requirements: **macOS 14 or later**, **Swift 6** (Xcode 16+ or compatible Command Line Tools), **Rust via [rustup](https://rustup.rs/)**, and Git. Check `swift --version` first. `rust-toolchain.toml` pins Rust 1.90.0; Cargo dependencies are locked. Python 3 is needed for probe tests and on each remote host. The app bundles its Rust executable; users and remote hosts do not need Rust installed.

```sh
git clone https://github.com/EdgarHnd/Burro.git
cd Burro
./script/build_and_run.sh
```

This builds and launches `dist/Burro.app`. Copy it to your Applications folder if you want to keep it. The build generates the dark butter icon from the included original vector mascot. Xcode 26+ builds enable Liquid Glass on macOS 26; older toolchains and systems use the native frosted material.

Parent-owned Rust workers process Codex lifecycle logs, Claude delegated-worker logs and desktop completion metadata, and on-demand token history for Codex, Claude and Grok. Unchanged files reuse bounded caches of lifecycle summaries or token counters; conversation text is never cached. History runs in a separate child so it cannot block live agent status. Swift retains the native UI, live lock/process checks, provider connections, pricing and cleanup policy. Failed or timed-out workers recover through Swift readers and can restart after a cooldown. There is no network listener, login item or background service. Burro remains a hybrid Swift/Rust app.

Local monitoring wakes on filesystem changes, coalesces bursts and checks active or uncertain sessions every three seconds after scans. Quiet monitoring falls back to fifteen seconds; missing watcher support retains three-second checks. Remote monitoring continues every ten seconds. Shared lifecycle mappings and freshness thresholds live in `policy/session-status.json`; generated Swift/Rust/Python adapters and shared fixtures prevent drift.

For an optimized local build without launching:

```sh
CONFIGURATION=release ./script/build_and_run.sh --build-only
```

This release is **source-only**. Local builds preserve their selected Apple Development signing identity and refuse silent changes that would invalidate Keychain access. Fresh source builds without a certificate use ad-hoc signing. Set `BURRO_SIGNING_IDENTITY` to select an identity (`-` forces ad-hoc). Builds are not Developer ID signed or notarized; there is no prebuilt download or automatic updater. The build targets the architecture of the Mac that runs it.

## First run

1. Open Burro. It discovers repositories from `~/Dev`, Codex worktrees, and available agent metadata. Use **Add repository** for other folders.
2. Hover over the black strip at the top of your screen. Click a chat to open it, or use the pin to keep the panel visible. Choose **Today's chats** from the notch's **⋯** menu to browse chats active today, newest first, including idle and closed chats. Use **Active chats** to return to the attention queue. A camera notch is optional.
3. To monitor another machine, first verify your SSH connection in Terminal, then choose **Remote sessions → Add remote machine**. Burro uses your existing SSH configuration and verified host keys.

See the [usage guide](docs/usage.md) for status meanings, provider compatibility, unread tracking, remote setup, and keyboard shortcuts.

## Privacy and limitations

Burro reads local Git state, same-user process metadata, and provider session files. Chat titles and paths are shown in memory; configuration and protections are saved in macOS preferences. Transcript tails are inspected for lifecycle events, but message bodies are not retained or exported. The optional Usage dashboard asks the installed Codex app server for limits and reads selected Claude/Grok coding-app sign-ins in memory for fixed provider usage endpoints. Account-scoped quota history is stored locally; an on-demand scanner reads local token counters without retaining message text. It does not copy credentials to disk or import browser cookies; direct background Keychain reads never prompt, and Claude can supply quotas through its own bounded zero-turn CLI command when its Keychain grant resets. See the [usage guide](docs/usage.md#usage-limits) for setup and access details.

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

- `.build/release/burro-inspect --profile-agents` measures process, unread-state and complete local-agent refreshes.
- `.build/release/burro-inspect --profile` also measures cold/warm on-demand token history.
- `python3 -B script/profile_runtime.py --executable "$PWD/dist/Burro.app/Contents/MacOS/Burro" --seconds 30` samples the running app and observed child processes.
- `BURRO_REQUIRE_RUST_WORKER=1 BURRO_WORKER_BENCHMARK=1 swift test -c release --filter UsageLogWorkerTests.testSyntheticHistoryBenchmark` compares equal-coverage synthetic usage scans.

Output contains counts and timings, not chat text or paths. Inspector CPU/memory covers the parent; wall time includes the worker. Runtime CPU sampling can miss short-lived children, and summed RSS is not private footprint or battery consumption. Real token history can be partial under the existing file/time limits; compare identical complete fixtures before claiming parser speedups.
