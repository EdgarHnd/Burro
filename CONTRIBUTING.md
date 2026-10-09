# Contributing to Burro

Small, focused improvements are welcome. Open an issue before a larger feature or architectural change so the scope can be discussed first. Search existing issues before reporting a duplicate.

## Local setup

Use macOS 14+ with Swift 6, Rust through rustup (pinned in `rust-toolchain.toml`), and Git; Python 3 runs the remote reader fixtures. Clone the repository and run `./script/build_and_run.sh`. No provider account is required to build or run the synthetic tests.

Read [MODULE.md](MODULE.md) for ownership boundaries and [the usage guide](docs/usage.md) for expected behavior. Keep the app, core monitoring code, and remote Python reader separated. When provider interpretation changes, update matching Swift and Python fixtures together.

## Before opening a pull request

```sh
cargo test --manifest-path Rust/Cargo.toml --target-dir .build/rust --locked
./script/build_rust_worker.sh
BURRO_REQUIRE_RUST_WORKER=1 swift test
python3 -B script/test_remote_probe.py
CONFIGURATION=release ./script/build_and_run.sh --build-only
```

Use a logged-in macOS graphical session for `NotchPanelTests`; they exercise real windows and compositor frames. In headless environments, use `swift test --skip NotchPanelTests` and state that native interaction was not tested. CI intentionally uses that headless command; green CI alone does not validate hover feel, display placement, or animation.

Add a targeted regression test for behavioral fixes. For visual changes, describe the native checks performed, including Reduce Motion when relevant. Update the canonical usage/architecture docs when behavior or ownership changes. No new test is needed merely to repeat a color constant.

Edit shared event/status rules in `policy/session-status.json`, run `python3 -B script/generate_status_policy.py`, and update the independent fixtures in `policy/status-fixtures.json`. CI checks generated files. Codex and Claude lifecycle changes must preserve parity between `AgentParsing`, the Rust log worker, and the remote Python reader. The Swift integration tests compare Rust and Swift event/age/lock behavior, project discovery limits, and cross-provider cache isolation and exercise worker failure/recovery. Keep `Rust/Cargo.lock` checked in and use `--locked` for builds; the Rust worker has no network or provider-authentication responsibilities.

## Boundaries to preserve

- Background monitoring is read-only. Confirmed cleanup follows the [cleanup and recovery contract](docs/usage.md#cleanup-and-recovery). Never infer a disposable worktree from an error, stale sample, or missing provider data.
- Run fixed executables with argument arrays. Session titles, paths, branch names, and SSH settings are untrusted input.
- Keep remote and local session identities distinct. SSH must remain noninteractive, forwarding-free, and strict about known host keys.
- Do not acknowledge provider unread markers. Agent/session readers never read authentication files; optional usage readers may access only the selected provider sign-in as described in [SECURITY.md](SECURITY.md). Keep credentials in memory and prohibit background authentication prompts.
- Avoid adding background services, telemetry, provider hooks, or dependencies without discussion.

Use synthetic fixtures. Never submit live session databases, transcripts, SSH configuration, tokens, machine addresses, personal paths, or unredacted screenshots. `burro-inspect` produces private metadata and is not a safe bug-report attachment by default.

## Pull requests

Describe the problem, the resulting behavior, and the exact validation performed. Keep unrelated formatting/refactors separate. Contributions are accepted under the project's [MIT license](LICENSE). For vulnerabilities, use [private reporting](SECURITY.md), not a public issue.
