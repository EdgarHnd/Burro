# Burro remote Claude reply. Sent over SSH to a machine you added; Burro prepends
# REQUEST_B64 = base64(JSON). {"check": <uuid>} only reports whether that session can take a
# reply. {"args": [...], "cwd": <path>} (after you press Send) runs
# `claude --bg --resume <uuid> [--permission-mode M] [--model X] [--effort E] -- <message>`
# without a shell, only when nothing has that session open (Claude would fork a copy otherwise).
# Prints {"ok", "output"|"error"} as JSON. Nothing else is accepted.
import base64, json, os, re, shutil, subprocess, sys

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

def problem(claude, env, session):
    """Why this session can't take a reply now (something has it open), or None."""
    try:
        rows = json.loads(subprocess.run([claude, "agents", "--json", "--all"], env=env, stdin=subprocess.DEVNULL,
                                         capture_output=True, text=True, timeout=20).stdout or "[]")
    except Exception:
        return None
    row = next((r for r in rows if isinstance(r, dict) and str(r.get("sessionId", "")).lower() == session.lower()), None)
    if not row: return None
    if row.get("status") == "busy": return "Claude is working on this chat. You can reply when it's done."
    if row.get("kind") == "background":
        handle = str(row.get("id", ""))
        hint = (" (claude attach " + handle + ")") if re.match(r"^[0-9a-f]{6,36}$", handle) else ""
        return "This chat is still open as a background session on this machine. Attach to it there to reply" + hint + "."
    return "This chat is open in Claude Code (a terminal or the Claude app). Reply there: a reply from Burro would start a separate copy."

def main():
    req = json.loads(base64.b64decode(REQUEST_B64))  # noqa: F821 (prepended by Burro)
    check, args, cwd = req.get("check"), req.get("args"), req.get("cwd")
    if check is not None:
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
    reason = problem(claude, env, check if check is not None else args[2])
    if reason: done(False, error=reason)
    if check is not None: done(True, output="")
    try:
        result = subprocess.run([claude] + args, cwd=folder, env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=55)
    except subprocess.TimeoutExpired:
        done(False, error="Claude didn't start in time.")
    output = (result.stdout + result.stderr)[-2000:]
    if result.returncode != 0:
        lines = [l for l in output.splitlines() if l.strip()]
        done(False, error="Claude didn't continue: " + (lines[-1] if lines else "unknown error"))
    done(True, output=output)

main()
