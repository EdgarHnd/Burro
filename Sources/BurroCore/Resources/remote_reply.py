# Burro remote Claude reply. Sent over SSH to a machine you added; Burro prepends
# REQUEST_B64 = base64(JSON). {"check": <uuid>} only reports whether that session can take a
# reply, with "live": {kind, busy, idle, waiting, attached, handle} when something has it open.
# {"stop": <uuid>} (after you press Stop) runs `claude stop <short id>` only for a background
# session of that id, the short id taken from `claude agents --json` here and hex only.
# {"args": [...], "cwd": <path>} (after you press Send) runs
# `claude --bg --resume <uuid> [--permission-mode M] [--model X] [--effort E] -- <message>`
# without a shell, only when nothing has that session open (Claude would fork a copy otherwise).
# {"continue": [...same argv...], "cwd": <path>} (Send on a chat whose background session is
# idle) does the same, except that an idle background session of that id (not busy, not asking
# anything, no `claude attach` for it running here) is first stopped with `claude stop <short id>`
# (looked up here, hex only, never taken from the request) and the resume runs only once
# `claude agents` no longer lists it as running; otherwise nothing is sent. Its steps have short
# limits (agents 10 s, ps 5 s, stop 20 s, resume 55 s) so it ends inside Burro's 150 s wait.
# Running: `claude agents --json --all` also lists finished background sessions (no pid, no
# status, state done/failed/stopped); those don't count as open.
# Claude's output goes to a private temp file, never a pipe, with stdin /dev/null and its own session:
# a Claude daemon that `--bg` starts can't hold this script (or the SSH channel) open.
# Prints {"ok", "output"|"error"} as JSON. Nothing else is accepted.
import base64, json, os, re, shutil, subprocess, sys, tempfile, time

UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
NAME = re.compile(r"^[A-Za-z0-9._\[\]-]{1,80}$")
FLAGS = {"--permission-mode": {"manual", "acceptEdits", "plan"}, "--model": None, "--effort": None}

def done(ok, **fields):
    print(json.dumps(dict(ok=ok, **fields))); sys.exit(0)

def valid(args):
    if len(args) < 5 or args[:2] != ["--bg", "--resume"] or not UUID.match(args[2]): return False
    i = 3
    while i < len(args) and args[i] != "--":
        flag = args[i]
        if flag not in FLAGS or i + 1 >= len(args): return False
        value, allowed = args[i + 1], FLAGS[flag]
        if not NAME.match(value) or (allowed is not None and value not in allowed): return False
        i += 2
    return i == len(args) - 2 and args[i] == "--" and 0 < len(args[-1]) <= 100000

HANDLE = re.compile(r"^[0-9a-f]{6,36}$")
OTHER = re.compile(r"^([0-9a-f]{6,36}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$")
STOP_WAIT, STOP_POLL = 8.0, 0.4
CONTINUE_LOOKUP, CONTINUE_PS, CONTINUE_STOP, RESUME = 10, 5, 20, 55

def run(argv, env, cwd, timeout, keep=64 * 1024):
    """(exit code or None on timeout, last `keep` bytes of output). Output goes to a private temp
    file so a background process the command leaves running can't hold a pipe open."""
    fd, path = tempfile.mkstemp(prefix="burro-")
    try:
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=fd, stderr=fd, env=env, cwd=cwd,
                                    start_new_session=True, close_fds=True)
        except OSError as error:
            return 127, str(error)
        finally:
            os.close(fd)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            code = None
        with open(path, "rb") as handle:
            handle.seek(0, 2)
            handle.seek(max(0, handle.tell() - keep))
            return code, handle.read(keep).decode("utf-8", "replace")
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass

UNREADABLE = object()

def running(row):
    if row.get("kind") != "background": return True
    return row.get("pid") is not None or row.get("status") is not None or row.get("state") in ("working", "blocked")

def is_waiting(row):
    return row.get("status") == "waiting" or row.get("state") == "blocked"

def is_busy(row):
    return row.get("status") == "busy" or (row.get("kind") == "background" and row.get("status") is None and not is_waiting(row))

def is_idle(row):
    return row.get("status") == "idle" and not is_waiting(row)

def lookup(claude, env, session, timeout=20):
    """The running `claude agents` row for this session (the most restrictive when several
    match: interactive, busy, waiting, idle), None when nothing runs it, UNREADABLE on failure."""
    try:
        code, text = run([claude, "agents", "--json", "--all"], env, os.path.expanduser("~"), timeout, keep=4 * 1024 * 1024)
        rows = json.loads(text or "[]")
    except Exception:
        return UNREADABLE
    if code != 0 or not isinstance(rows, list): return UNREADABLE
    rows = [r for r in rows if isinstance(r, dict) and str(r.get("sessionId", "")).lower() == session.lower() and running(r)]
    rank = lambda r: 0 if r.get("kind") != "background" else 1 if is_busy(r) else 2 if is_waiting(r) else 4 if is_idle(r) else 3
    return min(rows, key=rank) if rows else None

def live_row(claude, env, session, timeout=20):
    """The `claude agents` row that has this session open, or None."""
    row = lookup(claude, env, session, timeout)
    return None if row is UNREADABLE else row

def attached(claude, env, handle, session, timeout=10):
    """Whether a `claude attach` for this session runs here: one naming its short id or session
    id, or a Claude attach by name or without a target. An unreadable process list counts."""
    ps = shutil.which("ps", path=env["PATH"])
    if not ps: return True
    code, text = run([ps, "-A", "-ww", "-o", "args="], env, os.path.expanduser("~"), timeout, keep=4 * 1024 * 1024)
    if code != 0: return True
    mine = {handle.lower(), session.lower()}
    for line in text.splitlines():
        tokens = line.split()
        for i, token in enumerate(tokens):
            if token != "attach" or i == 0: continue
            target = tokens[i + 1].lower() if i + 1 < len(tokens) else None
            if target in mine: return True
            if any("claude" in t.lower() for t in tokens[:i]) and (target is None or not OTHER.match(target)): return True
    return False

def continuable(row):
    handle = str(row.get("id", "")) if row else ""
    return bool(row) and row.get("kind") == "background" and is_idle(row) and HANDLE.match(handle) is not None

def live_info(row, attached_here=False):
    if not row: return None
    handle = str(row.get("id", ""))
    return {"kind": "background" if row.get("kind") == "background" else "interactive",
            "busy": is_busy(row), "idle": is_idle(row), "waiting": is_waiting(row), "attached": attached_here,
            "handle": handle if HANDLE.match(handle) else None}

def problem(row):
    """Why this session can't take a reply now (something has it open), or None."""
    if not row: return None
    if is_busy(row): return "Claude is working on this chat. You can reply when it's done."
    if row.get("kind") == "background" and is_waiting(row):
        return "Claude is waiting for you in this chat on this machine (a question or an approval). Attach to it there to answer."
    if row.get("kind") == "background":
        handle = str(row.get("id", ""))
        hint = (" (claude attach " + handle + ")") if HANDLE.match(handle) else ""
        return "This chat is still open as a background session on this machine. Attach to it there to reply" + hint + "."
    return "This chat is open in Claude Code (a terminal or the Claude app). Reply there: a reply from Burro would start a separate copy."

def main():
    req = json.loads(base64.b64decode(REQUEST_B64))  # noqa: F821 (prepended by Burro)
    check, stop, args, cwd, cont = req.get("check"), req.get("stop"), req.get("args"), req.get("cwd"), req.get("continue")
    if cont is not None:
        if not isinstance(cont, list) or not all(isinstance(a, str) for a in cont) or not valid(cont):
            done(False, error="Burro sent a request this machine won't run.")
        args, stop, check = cont, None, None
    elif stop is not None:
        if not isinstance(stop, str) or not UUID.match(stop): done(False, error="Burro sent a request this machine won't run.")
    elif check is not None:
        if not isinstance(check, str) or not UUID.match(check): done(False, error="Burro sent a request this machine won't run.")
    elif not isinstance(args, list) or not all(isinstance(a, str) for a in args) or not valid(args):
        done(False, error="Burro sent a request this machine won't run.")
    home = os.path.expanduser("~")
    path = os.pathsep.join([os.path.join(home, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
    claude = shutil.which("claude", path=path)
    if not claude: done(False, error="Claude Code isn't installed on this machine.")
    folder = cwd if isinstance(cwd, str) and cwd.startswith("/") and os.path.isdir(cwd) else home
    env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE_CODE_") or k == "CLAUDECODE" or k.startswith("GIT_"))}
    env["PATH"] = path
    if stop is not None:
        info = live_info(live_row(claude, env, stop))
        if not info or info["kind"] != "background" or not info["handle"]:
            done(False, error="This chat isn't running as a background session on this machine. Stop it where it runs.")
        code, output = run([claude, "stop", info["handle"]], env, home, 30, keep=2000)
        if code is None:
            done(False, error="Claude didn't stop in time.")
        if code != 0:
            lines = [l for l in output.splitlines() if l.strip()]
            done(False, error="Claude didn't stop it: " + (lines[-1][:300] if lines else "unknown error"))
        done(True, output="")
    session = check if check is not None else args[2]
    # Continue keeps every step short (agents 10 s, ps 5 s, stop 20 s), so with the resume it ends
    # well inside Burro's SSH timeout for it (150 s).
    lookup_t, ps_t, stop_t = (CONTINUE_LOOKUP, CONTINUE_PS, CONTINUE_STOP) if cont is not None else (20, 10, 30)
    row = live_row(claude, env, session, lookup_t)
    here = continuable(row) and attached(claude, env, str(row.get("id")), session, ps_t)
    stopped = False
    if cont is not None and continuable(row) and not here:
        # The one idle background session of this chat: stop it, confirm, then resume.
        code, output = run([claude, "stop", str(row.get("id"))], env, home, stop_t, keep=2000)
        if code != 0:
            lines = [l for l in output.splitlines() if l.strip()]
            done(False, error="Claude didn't stop the background session, so nothing was sent" + (": " + lines[-1][:300] if lines and code is not None else "."))
        deadline = time.monotonic() + STOP_WAIT
        while lookup(claude, env, session, lookup_t) is not None:
            if time.monotonic() >= deadline:
                done(False, error="The background session was still running after Burro stopped it, so nothing was sent. Try again in a moment.")
            time.sleep(STOP_POLL)
        stopped = True
    elif here:
        done(False, error="This chat is attached in a terminal on this machine. Reply there, or close that terminal first.", live=live_info(row, True))
    else:
        reason = problem(row)
        if reason: done(False, error=reason, live=live_info(row))
    if check is not None: done(True, output="")
    code, output = run([claude] + args, env, folder, RESUME, keep=2000)
    if code is None:
        done(False, error="Claude didn't start in time.")
    if code != 0:
        lines = [l for l in output.splitlines() if l.strip()]
        reason = "Claude didn't continue: " + (lines[-1] if lines else "unknown error")
        done(False, error=("Burro stopped the idle background session, but " + reason + ". The conversation is kept.") if stopped else reason)
    done(True, output=output)

main()
