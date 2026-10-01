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
- **Local by default:** no Burro account, analytics service, provider hooks, or third-party build dependencies. Native SwiftUI and AppKit, Swift 6, system SQLite, Git, and OpenSSH.

Background monitoring is read-only. **Move to Trash** is an explicit, confirmed action that rechecks Git and activity, preserves the whole checkout in Trash, unregisters only that worktree, and retains its branch. Codex-managed worktrees use Codex’s archive flow. Readiness is a point-in-time observation, not a guarantee. Burro does not automatically fetch Git refs or mark chats read. See [cleanup and recovery](docs/usage.md#cleanup-and-recovery).

## Build and run

Requirements: **macOS 14 or later**, **Swift 6** (Xcode 16+ or compatible Command Line Tools), and Git. Check `swift --version` first. Python 3 is needed for probe tests and on each remote host.

```sh
git clone https://github.com/EdgarHnd/Burro.git
cd Burro
./script/build_and_run.sh
```

This builds and launches `dist/Burro.app`. Copy it to your Applications folder if you want to keep it. The build generates the dark butter icon using your Mac's system emoji font.

For an optimized local build without launching:

```sh
CONFIGURATION=release ./script/build_and_run.sh --build-only
```

This release is **source-only**. Local builds reuse an available Apple Development signing identity for stable Keychain access, or fall back to ad-hoc signing without one. Set `BURRO_SIGNING_IDENTITY` to select an identity (`-` forces ad-hoc). Builds are not Developer ID signed or notarized; there is no prebuilt download or automatic updater. The build targets the architecture of the Mac that runs it.

## First run

1. Open Burro. It discovers repositories from `~/Dev`, Codex worktrees, and available agent metadata. Use **Add repository** for other folders.
2. Hover over the black strip at the top of your screen. Click a chat to open it, or use the pin to keep the panel visible. A camera notch is optional.
3. To monitor another machine, first verify your SSH connection in Terminal, then choose **Remote sessions → Add remote machine**. Burro uses your existing SSH configuration and verified host keys.

See the [usage guide](docs/usage.md) for status meanings, provider compatibility, unread tracking, remote setup, and keyboard shortcuts.

## Privacy and limitations

Burro reads local Git state, same-user process metadata, and provider session files. Chat titles and paths are shown in memory; configuration and protections are saved in macOS preferences. Transcript tails are inspected for lifecycle events, but message bodies are not retained or exported. The optional Usage dashboard asks the installed Codex app server for limits and reads selected Claude/Grok coding-app sign-ins in memory for fixed provider usage endpoints. Account-scoped quota history is stored locally; an on-demand scanner reads local token counters without retaining message text. It does not copy credentials to disk or import browser cookies; background Keychain reads never prompt. See the [usage guide](docs/usage.md#usage-limits) for setup and access details.

Remote monitoring sends a fixed inspection script to hosts you explicitly add and returns session metadata over SSH. It does not inherit Codex/Claude desktop pairings or monitor cloud-hosted tasks. The dashboard's cleanup advice covers local worktrees only.

CLI output and screenshots can contain private titles and filesystem paths. Review and redact them before sharing. See [SECURITY.md](SECURITY.md) for the trust model and private vulnerability reporting.

## Develop and contribute

```sh
swift test
python3 -B script/test_remote_probe.py
./script/build_and_run.sh --build-only
```

The AppKit panel tests require an active macOS graphical session. CI runs the other Swift tests and builds the app; the remote probe fixtures also run on Linux. See [CONTRIBUTING.md](CONTRIBUTING.md) and [architecture](MODULE.md).

A JSON CLI is included:

```sh
swift run burro-inspect --agents
swift run burro-inspect /path/to/repository
```

[Report a bug](https://github.com/EdgarHnd/Burro/issues/new/choose) · [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE). Codex, Claude, and macOS belong to their respective owners. Burro is an independent project and is not affiliated with OpenAI, Anthropic, or Apple. The repository contains icon-generation code, not bundled Apple font files or pre-rendered emoji artwork.
