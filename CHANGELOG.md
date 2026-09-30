# Changelog

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
