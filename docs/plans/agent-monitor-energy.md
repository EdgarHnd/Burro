# Brief: cut Burro's background energy use

Status: ready to pick up · Written 2026-11-06 from measurements taken 2026-10-29

## Goal

Burro should cost almost nothing while it watches agents. Today it averages **7–8% of one core** whenever agents are active, which puts it near the top of macOS's "Apps Using Significant Energy" on battery. Target: **≤ 2% average CPU** with the same detection behavior, no new background services, and every invariant in [MODULE.md](../../MODULE.md) intact.

Done means: the before/after numbers below are re-measured on a release build, tests pass (`BURRO_REQUIRE_RUST_WORKER=1 swift test`, `cargo test --locked`), and MODULE.md / docs/usage.md describe the new cadence and ownership.

## What was measured

Machine: 18-core Apple silicon, 48 GB, ~1,100 same-user processes, several Claude/Codex sessions active, one SSH remote host.

| Build | Burro CPU, 60 s average |
|---|---|
| Debug (`./script/build_and_run.sh`) | 8.4% |
| Release (`CONFIGURATION=release ./script/build_and_run.sh`) | 7.0% |

A release build barely helps, so the cost is the work done, not Swift codegen. Use the release build for daily use anyway.

One `AgentMonitor.sample()` costs **~122 ms CPU** (debug, with the Rust worker attached) and runs **every 3 s** while any session is active (`AgentRefreshCoordinator`). Profile of a tight loop of `AgentMonitor().sample()` (inclusive share of samples):

| Share | Where | Why it is expensive |
|---|---|---|
| ~39% | `ProviderReadState.read` → `ChromiumReadState.value/readValue/records` | Re-reads Claude desktop's Local Storage LevelDB (~2.4 MB: a ~1.5 MB `MANIFEST`, `.ldb` tables, the `.log`) on almost every sample. **33% of the total is `ChromiumReadState.checksum`**, a byte-at-a-time table CRC32C. The cache (`ChromiumReadStateCache`, uncommitted work below) keys on every file's stamp, and Claude appends to the `.log` constantly while in use, so it almost never hits. |
| ~25% | `AgentReader.codex` | `lstat`/`open`/JSON on the same Codex session and state files each round. |
| ~15% | `AgentLogWorker.exchange` / `readLine` | Waiting on the Rust worker (`burro-log-worker`). This is blocked time, not Burro CPU; the worker itself averaged < 1% CPU. |
| ~9% | `ProcessReader.snapshot` | `proc_pidinfo` BSD + vnode-path info for every process. |

Also: `RemoteAgentMonitor` opens an SSH connection to each enabled host **every 10 s**; each probe took ~3 s of wall time (the remote Python probe), so ssh is running about a third of the time.

Not a problem: Burro's memory stayed flat (~102 MB over 3.5 h; no leak). Mac Health costs nothing while closed and ~2 ms CPU/s while on screen; its cost is kernel calls (debug ≈ release), so **do not port Mac Health to Rust**.

## Plan

Do these in order and measure after each step. Steps 2–3 follow the existing architecture: the Rust worker already owns Codex log and Claude transcript parsing behind a bounded stdio protocol.

### 1. Land the pending local work first (prerequisite)

The owner's main checkout has uncommitted work from 2026-10-10 that overlaps this plan: `Rust/src/catalog.rs` + `Sources/BurroCore/CodexCatalog.swift` (Codex catalog moving to Rust), `ChromiumReadStateCache.swift`, `GitFactsCache.swift`, `WorktreeRefreshPolicy.swift` (skip worktree scans while the dashboard is hidden), an event-filtered `AgentFileWatcher`, and a `CommandRunner` that waits on process exit instead of polling 40×/s. It builds and its tests pass. **Ask the owner to commit or push it before starting**, otherwise this work will conflict with it.

### 2. Claude unread state → Rust, incremental (biggest win, ~39%)

Add a protocol request to `burro-log-worker` that returns the allowlisted Claude preference value, replacing the Swift reader on the hot path (keep Swift as the fallback, as `AgentLogWorker` already does).

- Cache parsed `.ldb` tables and the `MANIFEST` by file identity (device, inode, size, mtime/ctime). They change only on compaction.
- Read only the bytes appended to the current `.log` since the last offset; restart from zero if the file is replaced, truncated or rotated.
- Use the CPU's CRC32C instruction (`std::arch::aarch64::__crc32cd`, with a table fallback on other targets) instead of a per-byte table loop. Adding a crate such as `crc32c` needs the owner's OK (CONTRIBUTING: no new dependencies without discussion).
- Keep today's guarantees: validate checksums, honor sequence numbers and deletion markers, fail closed on any inconsistency (never reuse a stale unread value), no locks on the provider database, and nothing but the requested value crosses the pipe.
- Port `Tests/BurroCoreTests/ChromiumReadStateTests.swift` fixtures to Rust and keep a Swift/Rust parity test.

Expected: this share drops from ~45 ms to well under 1 ms per sample when only the `.log` grew.

### 3. Codex discovery → Rust with a stat cache (~25%)

Extend the catalog work from step 1 so the worker returns Codex session metadata and only re-reads files whose stamp changed. Swift keeps process identity, lock checks, and cleanup ownership (MODULE.md boundaries).

### 4. Sample on change, slow down on battery

- Let `AgentFileWatcher` events drive refreshes; when nothing changed and no session is waiting or working, use the long fallback instead of 3 s.
- On battery (IOKit power-source notifications) or Low Power Mode: active checks 3 s → 10 s, quiet fallback 15 s → 60 s, remote SSH 10 s → 30 s. Back to normal on AC. Show the slower cadence in Settings / the sidebar footer so status age stays honest.
- Consider keeping one SSH connection open (OpenSSH `ControlMaster`) instead of a new handshake every probe, only if it keeps today's strict, non-interactive, forwarding-free SSH rules.

### 5. Cheaper process snapshot (~9%, optional)

Skip the vnode/cwd lookup for app-bundle processes and processes whose identity (pid + start time) was seen in the previous snapshot.

## How to measure

- Live average: `top -l 13 -s 5 -pid <Burro pid> -stats pid,cpu` after a 2–3 minute warm-up (startup scans run hot).
- Where the time goes: loop `AgentMonitor().sample()` in a throwaway XCTest for 10 s and run `sample <xctest pid> 5` against it. Release test builds cannot find the Rust worker (`AgentLogWorker.bundledExecutable` only checks `.build/rust` in DEBUG), so profile debug tests or the packaged app.
- Compare on the same machine and agent load; numbers swing a few percent with agent activity.

## Out of scope

Mac Health (already cheap and only active while visible), provider usage polling, and any change to detection semantics or unread/Done rules.
