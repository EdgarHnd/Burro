#!/usr/bin/env python3
"""Read session metadata on a Mac/Linux SSH host; emit no credentials or transcript bodies."""
import calendar
from datetime import datetime
import errno
import fcntl
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

LIMIT = 2000
TAIL_LIMIT = 512 * 1024

# BEGIN GENERATED STATUS POLICY
CODEX_EVENTS = {
    'task_started': ('Working', False),
    'turn_started': ('Working', False),
    'task_complete': ('Open · idle', True),
    'turn_complete': ('Open · idle', True),
    'task_aborted': ('Open · idle', False),
    'turn_aborted': ('Open · idle', False),
    'request_user_input': ('Needs input', False),
    'approval_required': ('Needs input', False),
}
CLAUDE_ALIASES = {
    'working': 'Working',
    'running': 'Working',
    'busy': 'Working',
    'processing': 'Working',
    'waiting': 'Needs input',
    'waiting_for_input': 'Needs input',
    'needs_input': 'Needs input',
    'awaiting_approval': 'Needs input',
    'waiting_for_permission': 'Needs input',
    'idle': 'Open · idle',
}
WORKING_SECONDS = 120
RECENT_SECONDS = 300
# END GENERATED STATUS POLICY



def held_lock(path):
    try:
        with open(path, "rb") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(handle, fcntl.LOCK_UN)
                return 0
            except OSError as error:
                return 1 if error.errno in (errno.EAGAIN, errno.EWOULDBLOCK) else -1
    except FileNotFoundError:
        return 0
    except OSError:
        return -1


def codex_event(tail):
    for line in reversed(tail.splitlines()):
        try:
            event = json.loads(line)
            if event.get("type") == "event_msg":
                kind = event.get("payload", {}).get("type")
                if isinstance(kind, str) and kind in CODEX_EVENTS:
                    return CODEX_EVENTS[kind]
        except (ValueError, AttributeError, TypeError):
            continue
    return (None, False)


def codex_state(tail, held, modified, now):
    if held < 0:
        return "Unknown"
    last, _ = codex_event(tail)
    age = now - modified if modified is not None else None
    if held == 1:
        return last or ("Working" if age is not None and 0 <= age < WORKING_SECONDS else "Unknown")
    if last == "Open · idle":
        return "Inactive"
    return "Recent activity" if age is not None and 0 <= age < RECENT_SECONDS else "Inactive"


def codex_completed(tail):
    return codex_event(tail)[1]


def claude_completed(home):
    completed = set()
    root = home / "Library/Application Support/Claude/claude-code-sessions"
    for path in root.glob("*/*/local_*.json"):
        try:
            if path.stat().st_size > 1024 * 1024:
                continue
            record = json.loads(path.read_bytes())
            if record.get("completedTurns", 0) > 0 and not record.get("isArchived"):
                completed.add(record.get("sessionId"))
        except (OSError, ValueError, TypeError):
            continue
    return completed

def session(sid, provider, title, cwd, state, updated, evidence, pid=None, pinned=False):
    return dict(id=sid, provider=provider, title=str(title)[:1000], cwd=str(cwd)[:4096], attachedPaths=[],
                state=state, updatedAt=float(updated), evidence=evidence, pid=pid, pinned=pinned)


def claude_state(status, live):
    if live is None:
        return "Unknown"
    if not live:
        return "Inactive"
    return CLAUDE_ALIASES.get(str(status).lower(), "Unknown")


def claude_identity(pid, expected):
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    try:
        result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "uid=", "-o", "lstart=", "-o", "comm="],
                                capture_output=True, text=True, timeout=1,
                                env=dict(os.environ, LC_ALL="C", LANG="C"))
        if result.returncode != 0:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            except OSError:
                return None
            return None
        fields = result.stdout.strip().split(None, 6)
        if len(fields) != 7 or int(fields[0]) != os.getuid():
            return False
        executable = fields[6]
        if Path(executable).name != "claude" and "/claude/versions/" not in executable:
            return False
        started = time.mktime(time.strptime(" ".join(fields[1:6]), "%a %b %d %H:%M:%S %Y"))
        stamp = time.strptime(expected, "%a %b %d %H:%M:%S %Y")
        return True if any(abs(started - candidate) < 2 for candidate in (time.mktime(stamp), calendar.timegm(stamp))) else None
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return None




# Claude can report idle while an in-process agent or background command still runs.
# Inspect only lifecycle envelopes and output-descriptor names; never read task output.
def claude_worker_tail_state(tail, sid, agent_id, started, now, modified):
    identified = False
    for line in reversed(tail.splitlines()):
        try:
            event = json.loads(line)
            if isinstance(event, dict) and isinstance(event.get("sessionId"), str) and isinstance(event.get("agentId"), str):
                identified = True
            if (not isinstance(event, dict) or event.get("sessionId") != sid
                    or event.get("agentId") != agent_id or event.get("isSidechain") is not True):
                continue
            if event.get("type") not in ("assistant", "user"):
                continue
            stamp = datetime.fromisoformat(event["timestamp"].replace("Z", "+00:00")).timestamp()
            if not math.isfinite(stamp) or stamp < started - 2:
                continue
            if stamp > now + 5:
                return "Unknown"
            message = event.get("message", {})
            if not isinstance(message, dict):
                continue
            if event["type"] == "assistant" and message.get("stop_reason") in ("end_turn", "stop_sequence"):
                return None
            # SubagentHandback ends on a user tool-result envelope, without a
            # subsequent assistant stop_reason. Read the flag, never result text.
            content = message.get("content")
            if (event["type"] == "user" and event.get("toolEndsTurn") is True
                    and isinstance(content, list)
                    and any(isinstance(block, dict) and block.get("type") == "tool_result" for block in content)):
                return None
            # Silence is not proof of completion. Retain uncertainty after fresh progress expires.
            return "Working" if -5 <= now - stamp <= 120 and -5 <= now - modified <= 120 else "Unknown"
        except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
            continue
    return "Unknown" if tail.strip() and not identified else None


def claude_worker_states(home, sid, started, now, deadline):
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", sid):
        return []
    root = home / ".claude/projects"
    if not root.exists():
        return []
    states = []
    # Registry cwd may change after worktree creation; parent UUID is the ownership boundary.
    for index, project in enumerate(root.iterdir()):
        if index >= 4096 or time.monotonic() > deadline:
            return states + ["Unknown"]
        if not project.is_dir() or project.is_symlink():
            continue
        directory = project / sid / "subagents"
        if not directory.is_dir() or directory.is_symlink() or directory.parent.is_symlink():
            continue
        for count, path in enumerate(directory.glob("agent-*.jsonl")):
            if count >= 256 or time.monotonic() > deadline:
                return states + ["Unknown"]
            agent_id = path.stem[len("agent-"):]
            if path.is_symlink() or not re.fullmatch(r"[a-zA-Z0-9_-]{1,128}", agent_id):
                continue
            try:
                with path.open("rb") as handle:
                    modified = os.fstat(handle.fileno()).st_mtime
                    if modified < started - 2:
                        continue
                    handle.seek(0, 2)
                    handle.seek(max(0, handle.tell() - TAIL_LIMIT))
                    tail = handle.read(TAIL_LIMIT).decode("utf-8", errors="replace")
                state = claude_worker_tail_state(tail, sid, agent_id, started, now, modified)
                if state:
                    states.append(state)
            except OSError:
                states.append("Unknown")
    return states


def claude_process_tree():
    result = subprocess.run(["/bin/ps", "-axo", "uid=,pid=,ppid="], capture_output=True,
                            text=True, timeout=1, env=dict(os.environ, LC_ALL="C", LANG="C"))
    if result.returncode != 0:
        raise OSError("Process tree unavailable")
    rows = {}
    for line in result.stdout.splitlines():
        values = line.split()
        if len(values) == 3 and all(v.isdigit() for v in values) and int(values[0]) == os.getuid():
            rows[int(values[1])] = int(values[2])
    return rows


def claude_descendants(parent, rows):
    found, frontier = set(), {parent}
    for _ in range(32):
        children = {pid for pid, ppid in rows.items() if ppid in frontier and pid not in found and pid != parent}
        if not children:
            return found
        found.update(children)
        if len(found) > 256:
            raise OSError("Descendant inspection limit")
        frontier = children
    raise OSError("Descendant depth limit")


def claude_task_id(path, sid):
    # Exact session-scoped Claude task output, not arbitrary child processes or shared cwd.
    parts = Path(path).parts
    if (len(parts) < 6 or parts[-3:-1] != (sid, "tasks")
            or not re.fullmatch(r"[a-zA-Z0-9_-]{1,128}\.output", parts[-1])
            or parts[-5] != "claude-" + str(os.getuid())):
        return None
    if Path(*parts[:-5]) not in (Path("/tmp"), Path("/private/tmp")):
        return None
    return Path(parts[-1]).stem


def claude_task_descriptors(output, sid, descendants, owners=False):
    tasks, pid, writable = {}, None, False
    for line in output.splitlines():
        if line.startswith("p"):
            pid = int(line[1:]) if line[1:].isdigit() else None
            writable = False
        elif line.startswith("f"):
            writable = False
        elif line.startswith("a"):
            writable = line[1:] in ("w", "u")
        elif line.startswith("n") and pid in descendants and writable:
            task = claude_task_id(line[1:], sid)
            if task:
                tasks.setdefault(task, set()).add(pid)
    return tasks if owners else set(tasks)


def claude_background_tasks(pid, sid, rows, owners=False):
    if pid not in rows:
        raise OSError("Parent process is absent from the inspection snapshot")
    descendants = claude_descendants(pid, rows)
    if not descendants:
        return {} if owners else set()
    if sys.platform == "darwin":
        result = subprocess.run(["/usr/sbin/lsof", "-a", "-p", ",".join(map(str, sorted(descendants))),
                                 "-d", "1,2", "-Fpfan"], capture_output=True, text=True, timeout=1)
        if result.returncode not in (0, 1) or result.stderr.strip():
            raise OSError("Task descriptors unavailable")
        return claude_task_descriptors(result.stdout, sid, descendants, owners)
    tasks = {}
    for child in descendants:
        for fd in ("1", "2"):
            try:
                root = Path("/proc") / str(child)
                flags = next(line.split()[1] for line in (root / "fdinfo" / fd).read_text().splitlines() if line.startswith("flags:"))
                if int(flags, 8) & os.O_ACCMODE not in (os.O_WRONLY, os.O_RDWR):
                    continue
                task = claude_task_id(os.readlink(root / "fd" / fd), sid)
                if task:
                    tasks.setdefault(task, set()).add(child)
            except (FileNotFoundError, ProcessLookupError):
                continue
            except (PermissionError, ValueError, StopIteration):
                raise OSError("Task descriptors unavailable")
    return tasks if owners else set(tasks)


def claude_scheduled_tasks(tasks, rows):
    # Read executable names, never command arguments. A sleep elsewhere in the session does not count.
    branches = {}
    for task, owners in tasks.items():
        branch = set(owners)
        for pid in owners:
            branch.update(claude_descendants(pid, rows))
        branches[task] = branch
    pids = set().union(*branches.values())
    result = subprocess.run(["/bin/ps", "-p", ",".join(map(str, sorted(pids))), "-o", "pid=,comm="],
                            capture_output=True, text=True, timeout=1)
    if result.returncode != 0:
        return False
    names = {}
    for line in result.stdout.splitlines():
        values = line.strip().split(None, 1)
        if len(values) == 2 and values[0].isdigit():
            names[int(values[0])] = Path(values[1]).name
    wrappers = {"sh", "bash", "zsh", "dash", "ksh"}
    return all(any(names.get(pid) == "sleep" for pid in branch) and
               all(names.get(pid) == "sleep" or
                   (names.get(pid) in wrappers and any(rows.get(child) == pid for child in branch))
                   for pid in branch) for branch in branches.values())


def claude_delegated_state(home, record, live, now, deadline, process_rows):
    if live is not True:
        return None, 0
    sid = record["sessionId"]
    states = []
    try:
        started = float(record.get("startedAt", 0)) / 1000
        # Without an incarnation boundary, old worker logs cannot imply live work.
        if math.isfinite(started) and started > 0:
            states = claude_worker_states(home, sid, started, now, deadline)
        if time.monotonic() > deadline or process_rows is False:
            raise OSError("Background process visibility is incomplete")
        tasks = claude_background_tasks(record["pid"], sid, process_rows, owners=True)
        if "Working" in states:
            return "Working", len(tasks) + states.count("Working")
        if tasks:
            try:
                scheduled = time.monotonic() <= deadline and claude_scheduled_tasks(tasks, process_rows)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                scheduled = False  # Owned live work is certain even if its sleep phase is not.
            if scheduled:
                return ("Unknown", 0) if "Unknown" in states else ("Scheduled", len(tasks))
            return "Working", len(tasks)
        return ("Unknown", 0) if "Unknown" in states else (None, 0)
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired):
        return ("Working", states.count("Working")) if "Working" in states else ("Unknown", 0)


def codex_is_subagent(source):
    if source in ('subagent', '"subagent"'):
        return True
    try:
        value = json.loads(source)
        return isinstance(value, dict) and "subagent" in value
    except (ValueError, TypeError):
        return False


def codex_parent_id(source):
    try:
        value = json.loads(source)["subagent"]["thread_spawn"]["parent_thread_id"]
        if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value):
            return "codex:" + value
    except (ValueError, TypeError, KeyError):
        pass
    return None


def codex_display_name(name, title, is_subagent):
    for value in (name, title):
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "Codex sub-agent" if is_subagent else "Untitled chat"

def codex_rows(path):
    def query(immutable=False):
        uri = path.resolve().as_uri() + "?mode=ro" + ("&immutable=1" if immutable else "")
        db = sqlite3.connect(uri, uri=True, timeout=1)
        try:
            db.execute("PRAGMA query_only=ON")
            columns = {row[1] for row in db.execute("PRAGMA table_info(threads)")}
            pinned = "is_pinned" if "is_pinned" in columns else "0"
            name = "name" if "name" in columns else "NULL"
            source = "source" if "source" in columns else "NULL"
            return list(db.execute("SELECT id,cwd,title,updated_at,rollout_path," + pinned + "," + name + "," + source +
                                   " FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 2001"))
        finally:
            db.close()
    try:
        return query()
    except sqlite3.OperationalError:
        # SQLite's read-only WAL mode may try to create absent sidecars. Only a
        # stable checkpoint with no journal can be read without those sidecars.
        journals = [Path(str(path) + suffix) for suffix in ("-wal", "-journal")]
        if any(p.exists() for p in journals):
            raise
        before = path.stat()
        rows = query(immutable=True)
        after = path.stat()
        if any(p.exists() for p in journals) or (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
            raise sqlite3.OperationalError("Checkpoint changed during inspection")
        return rows

def collect(home):
    now, deadline = time.time(), time.monotonic() + 8
    sessions, warnings = [], []
    codex = home / ".codex"
    if codex.exists():
        try:
            files = [p for p in codex.glob("state_*.sqlite") if re.fullmatch(r"state_\d+\.sqlite", p.name)]
            files.sort(key=lambda p: int(re.search(r"\d+", p.name).group()), reverse=True)
            if not files:
                warnings.append("Codex session database is unavailable.")
            else:
                rows = codex_rows(files[0])
                if len(rows) > LIMIT:
                    warnings.append("Codex history exceeds the inspection limit; some sessions may be absent.")
                # Inspect open writers first, then bounded history for completed results.
                # No viewer read-state or chat identifiers are sent to this host.
                selected = [(row, held_lock(codex / "thread-writer-locks" / (str(row[0]) + ".lock")))
                            for row in rows[:LIMIT] if isinstance(row[0], str) and "/" not in row[0]]
                selected.sort(key=lambda pair: pair[1] == 0)
                for (sid, cwd, title, updated, rollout, pinned, name, source), held in selected:
                    if time.monotonic() > deadline - 3:
                        warnings.append("Remote inspection reached its time limit.")
                        break
                    if not isinstance(sid, str) or "/" in sid or not cwd:
                        warnings.append("A Codex session record could not be read.")
                        continue
                    is_subagent = codex_is_subagent(source)
                    # Completed child runs are not unread chats in the provider sidebar.
                    # Retain live/uncertain workers for activity and safety evidence.
                    if is_subagent and held == 0 and now - float(updated or 0) >= 600:
                        continue
                    modified, tail = None, ""
                    try:
                        with open(rollout, "rb") as handle:
                            handle.seek(0, 2)
                            handle.seek(max(0, handle.tell() - TAIL_LIMIT))
                            tail = handle.read(TAIL_LIMIT).decode("utf-8", errors="replace")
                            modified = os.fstat(handle.fileno()).st_mtime
                        state = codex_state(tail, held, modified, now)
                    except (OSError, TypeError):
                        state = "Unknown" if held != 0 else "Inactive"
                    completed = codex_completed(tail)
                    # Retain recent closed chat metadata so the viewer can apply
                    # its own local day boundary, even across different time zones.
                    recent_chat = not is_subagent and now - 48 * 3600 <= float(updated or 0) <= now
                    if state != "Inactive" or completed and not is_subagent or recent_chat:
                        sessions.append(session("codex:" + sid, "Codex", codex_display_name(name, title, is_subagent), cwd, state, updated or 0,
                                                "Remote writer lock and turn event metadata.", pinned=bool(pinned)))
                        sessions[-1]["turnCompleted"] = completed
                        sessions[-1]["isSubagent"] = is_subagent
                        sessions[-1]["parentSessionID"] = codex_parent_id(source)
        except (OSError, sqlite3.Error, ValueError, TypeError):
            warnings.append("Codex session metadata could not be read on this host.")
    claude = home / ".claude/sessions"
    if claude.exists():
        try:
            files = list(claude.glob("*.json"))
            completed = claude_completed(home)
            process_rows = None
            if len(files) > LIMIT:
                warnings.append("Claude session records exceed the inspection limit.")
            for path in files[:LIMIT]:
                if time.monotonic() > deadline:
                    warnings.append("Remote inspection reached its time limit.")
                    break
                try:
                    if path.stat().st_size > 1024 * 1024:
                        raise ValueError("Large metadata record")
                    record = json.loads(path.read_bytes())
                    sid, cwd, pid = record["sessionId"], record["cwd"], record["pid"]
                    if not isinstance(sid, str) or not isinstance(cwd, str):
                        raise ValueError("Invalid session identity")
                    live = claude_identity(pid, record.get("procStart"))
                    state = claude_state(record.get("status", ""), live)
                    delegated, delegated_count = None, 0
                    if live is True and state == "Open · idle":
                        if process_rows is None:
                            try:
                                process_rows = claude_process_tree()
                            except (OSError, subprocess.TimeoutExpired):
                                process_rows = False
                                warnings.append("Claude background process visibility is limited on this host.")
                        delegated, delegated_count = claude_delegated_state(home, record, live, now, deadline, process_rows)
                        if delegated:
                            # Recheck the parent incarnation after inspecting its descendants.
                            if claude_identity(pid, record.get("procStart")) is True:
                                state = delegated
                            else:
                                state = "Unknown"
                    desktop_id = record.get("hostSessionId")
                    has_result = isinstance(desktop_id, str) and desktop_id in completed and record.get("status") == "idle" and state in ("Open · idle", "Inactive")
                    updated = float(record.get("updatedAt", record.get("startedAt", 0))) / 1000
                    if state != "Inactive" or has_result or now - 48 * 3600 <= updated <= now:
                        sessions.append(session("claude:" + sid, "Claude Code", record.get("name") or "Claude Code session",
                                                cwd, state, updated, "Remote PID/start-time identity and reported session status.", pid=pid if live else None))
                        sessions[-1]["turnCompleted"] = has_result
                        if delegated == "Working" and state == "Working":
                            sessions[-1]["evidence"] = "Verified Claude process with %d active delegated task(s); parent reports idle." % delegated_count
                        elif delegated == "Scheduled" and state == "Scheduled":
                            sessions[-1]["evidence"] = "Verified Claude background task waiting in a live sleep delay; resumes automatically."
                        elif delegated == "Unknown":
                            sessions[-1]["evidence"] = "Claude reports idle; delegated work could not be confirmed complete."
                        for source, target in (("hostSessionId", "claudeDesktopSessionID"),
                                               ("bridgeSessionId", "claudeBridgeSessionID")):
                            value = record.get(source)
                            if isinstance(value, str) and len(value) <= 128:
                                sessions[-1][target] = value
                except (OSError, ValueError, KeyError, TypeError):
                    warnings.append("A Claude session record could not be read on this host.")
        except OSError:
            warnings.append("Claude session metadata could not be read on this host.")
    elif (home / ".claude").exists():
        warnings.append("Claude session registry is unavailable on this host.")
    # Preserve live evidence first, then the newest history across both providers.
    sessions.sort(key=lambda item: (item["state"] == "Inactive", -item["updatedAt"]))
    if len(sessions) > LIMIT:
        warnings.append("Remote sessions exceed the inspection limit.")
    return dict(version=1, sessions=sessions[:LIMIT], warnings=sorted(set(warnings)))


if __name__ == "__main__":
    # An explicit home is used by isolated fixture tests; SSH invokes this script without arguments.
    home = Path(sys.argv[2]) if len(sys.argv) == 3 and sys.argv[1] == "--home" else Path.home()
    print(json.dumps(collect(home), ensure_ascii=True, allow_nan=False))
