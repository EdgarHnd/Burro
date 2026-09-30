# Burro

A small native macOS monitor for Git worktrees and Codex / Claude Code agents, with a live agent panel at the camera notch. Built with SwiftUI, Swift 6, and system libraries. Requires macOS 14 or newer. No provider accounts or hooks. Local monitoring stays on this Mac; remote monitoring uses SSH only for machines you explicitly add.

## Run

```sh
./script/build_and_run.sh
```

The script builds and ad-hoc signs `dist/Burro.app`. You can launch that bundle directly or copy it to Applications. Other modes: `--build-only`, `--verify`, `--debug`, `--logs`, `--telemetry`.

```sh
swift test
swift run burro-inspect --agents            # fast agent status, including unread results
swift run burro-inspect                     # JSON snapshot, automatic discovery
swift run burro-inspect /path/to/repository # limit to specified repositories
```

## Agent notch

- The notch is enabled by default. **Hover** over the black strip at the top of the screen to expand it; **click** to open or close; use the **pin button** to keep it open. Move away to collapse an unpinned panel, or use its chevron to collapse explicitly.
- The compact notch has two consistent status indicators: running agents on the left (waveform), and attention on the right (inbox: needs input plus Done/unread). It has no logo, name, or idle count. Amber means some attention is input-related; blue means unread completions only. The expanded summary shows the breakdown. When nothing is running but a task is scheduled, the left indicator becomes a teal clock and scheduled count.
- The expanded list prioritizes **Needs you → Done/unread → Running**, then uncertain activity, Scheduled, and recent activity. The large title and repeated count are removed; up to five complete rows fit. The options menu can include idle chats, refresh status, or open monitoring details. Done results remain until the provider marks them read; merely opening the notch never acknowledges them.
- Codex workers with an explicit parent ID are folded beneath their parent chat. Others, including Guardian runs without that metadata, appear in a collapsed **Background workers** group per machine. Worker input requests promote the group and remain visibly labeled. Counts still represent unique agents, including working/waiting children; grouping does not discard safety evidence or infer ownership from a shared folder. Claude sessions without explicit parent metadata remain separate chats.
- While the pointer or keyboard focus is in the expanded panel, list positions and worker membership stay fixed; titles/status update live. New/disappearing items reconcile after interaction ends, or when **Update list** is chosen. A disappeared row is disabled rather than replaced under the pointer. Selecting a different filter deliberately refreshes the list.
- Click a chat to open Codex or Claude; right-click → **Show in Burro** opens its details. Expand a worker group to open a specific worker. The footer arrow opens worktrees. Missing provider links fall back to Burro details.
- The separate read-only agent poll runs about every 3 seconds after each sample, independently of Git scanning. Footer notices name the affected machine and distinguish history coverage from connection failures. Click a notice for details, last successful remote check, and retry. Unknown/recent is not reported as confirmed running.
- Placement prefers the MacBook's notched display and reserves the camera's physical width. On every display, the black surface attaches flush to the physical top edge, including displays without a camera notch. Concave shoulders and rounded lower corners make it part of the screen edge, with no floating-window shadow. Layout updates when displays or Spaces change; the panel can appear alongside fullscreen apps.
- Hover opens immediately, including an 8-point approach area around the compact strip. The expanded panel has a 10-point edge tolerance and closes 120 ms after leaving. Returning cancels closing immediately. Passive pointer-movement observers work over Burro and other apps, independent of view tracking areas. Core Animation animates the outline and content fades, preserving motion through reversals while text stays at a fixed size. Deliberate collapse stays closed until the pointer leaves and returns. Opening with a click or keyboard does not silently pin the panel.
- Settings and the menu bar let you disable the notch or prefer the main display. **⇧⌘B** opens it while Burro is active. It does not install a global keyboard shortcut or request accessibility/input-monitoring permissions. Clicking inside the panel does not activate the dashboard unless you choose an agent/worktree link.
- The notch deliberately uses a black surface to blend with the camera housing, with restrained sage and amber accents. It respects Reduce Motion and keeps monitoring when the dashboard closes.

Chat navigation uses `codex://threads/<UUID>` and Claude's existing desktop/bridge session IDs. These are navigation-only links: Burro does not send a prompt, import/resume a CLI session, or change remote access settings. Bare Claude CLI sessions without desktop/bridge metadata open their Burro details. Exact Code-session routes were checked against the installed apps; private provider routes can change. See [Claude's URL scheme documentation](https://support.claude.com/en/articles/14729294-open-claude-desktop-with-a-link) for the public deep-link overview.

### Done and unread status

Burro reads the provider apps' saved unread markers on this Mac. A successful Codex completion event, or an idle Claude desktop session with completed turns, must also be present. Codex internal sub-agent/guardian runs never produce Done notifications, even if they retain unread markers. Live workers still appear as working or needing input. Codex rows prefer the app's saved display name over the original prompt. Working, scheduled, needs-input, unknown, and stale-remote states take precedence. Clicking a row opens the provider; Burro waits for its saved read marker to clear on the next local refresh. It does not mark chats read itself or use a recent-completion timer. Done is separate from worktree safety: an open idle process still keeps its worktree in use.

Codex stores read state per account and execution host in `.codex-global-state.json`. Burro selects the account from the newest thread with creator identity metadata (or the sole saved account on older installations), never unions account histories, and ignores legacy migration snapshots. Switching accounts without creating an attributed thread can leave that selection behind; missing/ambiguous schemas show a visibility warning. No authentication files or tokens are read.

Claude's `epitaxy-unread-v1` preference is read from its Chromium Local Storage, including manually unread IDs. The reader follows the current LevelDB manifest, sequence numbers and deletion markers, validates checksums, and reads only the relevant indexed blocks. It does not open or lock the provider database. Missing registry/session metadata can prevent a Done badge; unsupported or changing storage fails closed and is retried on the next refresh. The format reader follows [LevelDB tables](https://github.com/google/leveldb/blob/main/doc/table_format.md) and [logs](https://github.com/google/leveldb/blob/main/doc/log_format.md).

Remote SQLite reads can use a stable, journal-free checkpoint when read-only WAL access is unavailable; a changed checkpoint or live journal cancels that fallback. Remote hosts return completion metadata; this Mac applies its own unread list using Codex thread UUIDs and Claude bridge IDs. Local unread IDs are never sent over SSH. Remote Codex completion history shares the existing 2,000-row/inspection-time limits; unread results beyond that coverage may be missing. Another laptop's `local_` Claude ID is never treated as a local read marker. Offline results become Last seen, not Done.

## Use

- Burro automatically discovers repositories from Codex projects, Claude sessions, `~/Dev` (two directory levels), and `~/.codex/worktrees` (three levels). **Add repository** covers other locations. Git's registered worktree list includes inactive, detached, locked, and missing worktrees.
- Filter by working, in use, inactive, safe candidates, protected, or repository. Search branches, paths, and chat titles.
- Select a worktree to see cleanup reasons, live agents, session history, uncommitted changes, ignored data, comparison branch, and local processes.
- Protect a worktree with the lock button. Manual protection is stored in Burro preferences, not Git's lock state. Unprotecting never overrides other checks.
- Finder, Terminal, and Copy Path are available in the detail pane and context menu. Refresh is **⌘R**; add repository is **⇧⌘O**.
- The menu bar uses the fast agent feed. Git/worktree scans repeat 30 seconds after the previous scan completes and run away from the UI thread. Each scan uses at most four Git inspection lanes.
- Settings allows explicit repository roots, automatic discovery, and per-repository comparison branches. Automatic comparison uses `origin/HEAD`, then `origin/main`, `origin/master`, or `origin/staging`.

## Other laptops and servers

Open **Remote sessions → Add remote machine**, or add a machine in Settings. Give it a name and the SSH address/alias you already use, such as `user@laptop.local` or `devbox`. Confirm that `ssh` connects from this Mac first. The remote machine needs macOS or Linux, Python 3, and readable Codex / Claude Code session metadata in the remote user's home directory.

- Both providers appear in the same notch feed, labeled with the remote machine and workspace. Clicking a remote agent opens its chat in the provider app on this Mac when a usable link is available. Codex needs that host/thread in its connected-host catalog; Claude needs its existing remote session bridge. A Claude desktop session ID from another machine is never treated as local. Right-click → **Show in Burro** opens remote details. Local Finder/Terminal actions and local cleanup assessments never apply to remote paths.
- Remote checks run independently, 10 seconds after the preceding check, with at most four SSH processes at once. Slow or unavailable machines do not block local monitoring.
- A failed connection preserves the last observed sessions as **Last seen**, changes their state to unknown, and removes them from working/waiting totals. A sample older than 30 seconds also becomes stale. Pausing a host removes its sessions from the feed. Removing or editing a host cannot reintroduce responses from its old connection.
- OpenSSH uses your existing authentication, SSH configuration, and verified host keys. It runs noninteractively with agent/port forwarding disabled. Burro does not accept unknown host keys, install a helper, copy provider credentials, change provider settings, or open a listener on either machine. It sends a bundled Python reader over standard input and receives session metadata only.
- Codex and Claude's app-to-app pairings do not automatically authorize Burro. This version uses its own SSH connection; provider relay pairings and cloud-hosted tasks are not imported.
- An idle Claude parent, locally or over SSH, remains Running while verified child processes own its session-scoped background task output descriptors, or its subagent logs contain fresh unfinished lifecycle events. Ordinary helper processes and completed workers do not count. Long-running background commands (including servers) remain active until their processes exit. A task waiting in an explicit `sleep` delay shows **Scheduled** with a teal clock, stays in the active list, and does not count as Running or Needs you. This requires a session-owned task branch containing only sleep processes and waiting shell wrappers. Mixed tasks or active workers stay Running; ordinary OS sleeping/idle processes do not imply a schedule. After the delay, the next sample reflects the resumed command or completion. Burro does not infer a wake-up time or import provider scheduling systems. Worker progress expires to Unknown after two minutes without a terminal event; it is never treated as Done merely because the parent is idle. Waiting-for-permission status still takes priority. Worker logs predating the parent process incarnation are excluded. These checks inspect event envelopes and descriptor names, never task output or prompt bodies.
- Remote monitoring covers sessions, not remote worktree cleanup assessments. Codex writer locks/turn events and Claude process-start identity use the same conservative rules as local monitoring. Unsupported metadata appears as a visibility notice. Output, record counts, probe duration, and SSH runtime are bounded.
- Remote host names, addresses, optional ports, and enable flags are saved in Burro preferences. Session metadata remains in memory. No passwords, keys, tokens, or transcript message bodies are stored by Burro.

Provider documentation: [Codex remote connections](https://developers.openai.com/codex/remote-connections) and [Claude Code Remote Control](https://code.claude.com/docs/en/remote-control) describe the providers' separate connection models.

## What the labels mean

| Label | Evidence |
| --- | --- |
| **Keep** | Main checkout, protected branch, user protection, Git lock, pinned chat, agent/process usage, tracked/untracked changes, unfinished Git operation, unmerged or locally unpushed commits. |
| **Review** | Missing/prunable registration, ignored files, declared submodules, incomplete provider visibility, or a failed/timed-out/unknown Git check. |
| **Safe candidate** | No observed activity or protection; successful clean/untracked/ignored checks; HEAD contained in the comparison branch; all commits covered by local remote-tracking refs. |

A safe candidate is advisory, never a deletion guarantee. The scan is a point-in-time local observation; refs may be stale and processes may start after it. Monitoring refreshes origin remote-tracking refs at most every five minutes without changing local branches or files. The notch’s red Delete button offers explicit, confirmed local worktree removal after a fresh safety scan; it uses `git worktree remove` without force and keeps the branch. Active, protected, dirty, ignored-file, and uncertain cases are blocked. Burro does not prune, archive, force-remove, or change agent configuration. Remove Codex-managed worktrees through Codex's archive flow to preserve its managed snapshots and attachments. Ignored files are deliberately reviewed, including environments and dependencies.

## Agent detection and limits

- **Codex:** opens the newest `~/.codex/state_*.sqlite` read-only; joins chat workspaces and worktree attachments; inspects existing writer locks without creating them; reads bounded 512 KB transcript tails for turn-start/completion events. Held writer locks plus events distinguish working from open/idle. Recent unfinished events without a lock are marked recent activity, not confirmed running. Missing/unsupported schemas produce a visible notice and prevent safe-candidate classification.
- **Claude Code:** reads `~/.claude/sessions/*.json`, verifies the live executable, PID, and process start time, then uses its reported status plus bounded delegated-work checks for idle parents. Dead PIDs are inactive; uncertain or reused identities stay unknown. Unrecognized live status is unknown and protects the worktree.
- **Processes:** uses macOS libproc for same-user process working directories, including terminals and dev servers. The scanner and its descendants are excluded. A nested worktree owns its own activity instead of incorrectly attributing it to the main checkout.
- Provider formats are private implementation details, observed on this Mac in September 2026. Other versions can provide less detail; missing evidence is not evidence of safety. Other users' processes and hosts that have not been added to Burro are outside coverage. Legacy Claude versions without session registries rely on process evidence and show reduced coverage.
- Historical Claude sessions are limited to records retained in the local session directory; Burro does not crawl all old conversations. Codex history includes unarchived database records. The detail pane shows up to ten inactive records per worktree.
- Session titles and filesystem paths remain in memory/UI. Burro persists selected roots, comparison refs, discovery preference, manual protections, notch preferences, and explicit remote host configurations in `local.burro.worktrees` UserDefaults. On first launch after the Grove rename, it imports only the four original preference keys from `local.grove.worktrees` once, without overwriting existing Burro values. CLI JSON contains titles/paths and should be treated as local data. No telemetry is sent. Configured remote hosts receive only the fixed inspection script over SSH.

See [architecture](../MODULE.md) for implementation boundaries.

### Completed chat delivery badges

Git delivery labels describe the checkout shared by chats, not edits attributable to each chat:

- **Uncommitted changes**: tracked or untracked changes are present.
- **Needs push**: commits are ahead of the configured upstream, or a feature branch has no upstream.
- **Needs pull**: the checkout is behind its upstream; the subtitle also shows the behind count when other changes take priority.
- **Needs to merge**: a clean, published feature branch is not contained in its comparison branch.
- **Merged** (purple): a clean, published feature branch is contained in its comparison branch.
- **Done** (blue): an integration branch is synchronized with its upstream, or a completed chat lacks sufficient Git evidence for a delivery label.
- **Git operation**: a merge, rebase, or other Git operation is underway.

Shared integration branches (`main`, `master`, `staging`, `develop`, `development`, or a branch whose upstream is the configured comparison base) are checked against their own upstream, rather than being labeled unmerged into main. Changes take priority over push, pull, and merge status. Local app scans refresh origin refs at most every five minutes using a bounded, noninteractive fetch; Refresh status forces a fresh attempt. A fetch failure marks merge evidence unverified. Remote probes still use cached refs. Squash/rebase merges may require manual inspection.

Completed, still-open chats with pending delivery work remain visible after being read. Inactive historical chats are not revived merely because they share a dirty checkout. Live states and stale remote evidence retain priority. Local Git evidence refreshes on the worktree scan (about 30 seconds); remote checks share a bounded two-second Git budget.

### Worktree groups in the notch

The notch separates projects into bordered sections with bold folder headers, machine names, worktree totals, and spacing between repositories. Project identity uses the repository root locally and the common Git directory remotely, so linked worktrees stay together; separate machines remain labeled sections. Within each project, the notch groups visible chats by machine and checkout path. Rows show the actual branch when known, machine, folder name, chat count, and upstream behind count. Hover only over the far-right chevron to preview up to five chats; a “+N more” action expands the full list. Hovering the rest of the row does not open a preview. Click a row to expand it inline. Full checkout paths appear in previews and tooltips. Different hosts and paths remain separate even with matching branch names; discovered local ownership and remotely probed Git roots resolve nested working directories.

Header and compact-notch counts represent worktree groups, not chats. Each group contributes to exactly one status: needs input, running, scheduled, unknown, or its completed Git/done state. A checkout with multiple running chats counts as one running worktree. Chat counts remain in group subtitles. The total describes the visible checkout groups, not the entire Git worktree inventory.

Provider icons are bundled from official OpenAI Developers and Claude websites; see `Sources/Burro/Resources/PROVIDER_ICONS.md`.

Running worktree rows use a subtle green pulse (static with Reduce Motion). The blue trash count in the compact notch and “need deletion” summary count show verified merged linked checkouts that still exist, including local checkouts with no chats. Primary, missing, protected, locked, dirty, or actively running checkouts are excluded. Remote cleanup evidence is limited to successfully probed chat checkouts, and stale/unknown evidence is excluded. This is a cleanup review indicator, not a promise that deletion is safe; nothing is removed automatically. Local entries have a red Delete button with confirmation and a fresh safety scan; remote deletion is not supported. Scrolling remains enabled with hidden indicators. The expanded panel covers menu-bar items within its bounds and restores its regular window level on collapse.

The notch shows chats with recorded file-edit activity, filtering confirmed conversation-only chats without altering the full monitoring/safety inventory. Running, waiting, and scheduled chats remain visible when their edit history is missing or incomplete; a partial scan does not establish that no code was edited. Each chat shows green/red counts from successful structured edit events; worktree subtext shows the net Git diff against the comparison branch’s merge base, including readable untracked text files. Chat counts are cumulative edit-operation totals; worktree counts are net Git changes. Successful shell write commands establish edit activity but do not provide reliable line counts: missing counts are hidden rather than displayed as placeholder text. Logs are read on their own host, bounded to 16 MB, and only derived counts are returned; truncated/missing logs never imply a verified zero. Edits through unrecognized tools may not appear.

Merged checkout rows show **Review** and their scan blockers when removal is not eligible (for example an open chat or ignored `.env.local` files). **Delete** appears only for a current safe candidate and still performs a fresh check after confirmation. The blue total is a cleanup queue, not a count of checkouts guaranteed safe to delete.

The Delete action now explicitly allows idle attached chats and ignored files, as requested. Its confirmation states that ignored files (including local environment files) are removed. Running, waiting, scheduled, uncertain, or pinned sessions, local processes, tracked/untracked changes, and protection still block deletion. The dashboard’s general safety assessment remains conservative; Delete uses this explicit cleanup policy and rechecks Git immediately before removal.

Deletion checks only the selected checkout, without a repository-wide diff calculation or network fetch. Its progress is shared across notch views, so only one deletion runs at once. Background scans do not produce remote-machine errors; actual remote targets are reported separately. Git inspection has a deadline, and successful removals cannot be resurrected by an older background scan result.

Chat activity and worktree Git delivery are separate. Finished chat rows stay blue and never inherit shared “Uncommitted changes”, push, or merge warnings. Those warnings remain on the worktree (including alongside Running). A finished chat with no verified reference says “Delivery unverified”. If its latest assistant reply explicitly cites exactly one commit, Burro resolves it in that checkout, verifies it is contained in HEAD, and checks cached remote refs. The detail says “Reported commit verified” or “Reported commit on remote”; it does not claim all of the chat’s edits belong to that commit. Ambiguous/missing references remain unverified. Extraction and verification run on the same host as the log, without sending messages to an external model. Local reference evidence is rechecked at least every minute while the chat is inspected.

Projects in the notch rank by running worktree count, then running chat count, then most recent session activity. Worktrees within each project rank by running chat count and then most recent activity. Old completed projects fall below active projects; stale remote sessions do not count as running.
