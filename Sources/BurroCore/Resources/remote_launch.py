# Burro remote chat launcher. Sent over SSH to a machine you added; Burro prepends one line,
# REQUEST_B64 = base64(JSON {"op": "check" | "start", "folder": <absolute path>, "args": [...]}).
#   check: whether Claude Code is installed, the folder is a real directory you own (after resolving
#          links) and Claude has been trusted there. Launches nothing.
#   start: (after you press Start in Burro) the same checks; an untrusted folder is reported, never
#          trusted for you. Then `claude --bg --permission-mode M [--model X] [--effort E] -- <prompt>`
#          runs through your login shell, the folder and every argument passed as positional
#          parameters that the shell never parses. Its output goes to a private temp file, stdin is
#          /dev/null and it runs in its own session, so nothing holds this SSH channel open and the
#          chat outlives it. For up to 20 seconds it then collects what Burro's local start check
#          reads: the `claude agents --json --all` row for the new handle, that handle's job state
#          file and whether its transcript exists. If the session stopped at a prompt, ended, or never
#          confirmed, it reads the tail of `claude logs <handle>` and stops and removes that handle,
#          the one this run created, and nothing else.
# Prints one JSON object (the evidence, or an error). Nothing else is accepted.
import base64, json, os, pwd, re, shutil, stat, subprocess, sys, tempfile, time

UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
NAME = re.compile(r"^[A-Za-z0-9._\[\]-]{1,80}$")
HANDLE = re.compile(r"claude attach ([0-9a-f]{6,36})")
MODES = {"manual", "acceptEdits", "plan"}
SHELLS = {"zsh", "bash", "sh", "dash", "ksh"}
SCRIPT = 'cd -- "$1" || exit 70; shift; exec "$@"'
ENDED = {"done", "failed", "error", "errored", "exited", "killed", "stopped", "completed"}
VERIFY_SECONDS = 20.0
POLL_SECONDS = 0.5
MAX_CONFIG = 64 * 1024 * 1024


def done(**fields):
    print(json.dumps(fields, ensure_ascii=True, allow_nan=False)); sys.exit(0)


def refuse():
    done(ok=False, code="invalid", error="Burro sent a request this machine won't run.")


def valid_args(args):
    """Exactly a new chat: --bg --permission-mode M [--model X] [--effort E] -- prompt."""
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        return False
    if len(args) < 5 or args[:2] != ["--bg", "--permission-mode"] or args[2] not in MODES:
        return False
    i, seen = 3, set()
    while i < len(args) and args[i] != "--":
        flag = args[i]
        if flag not in ("--model", "--effort") or flag in seen or i + 1 >= len(args) or not NAME.match(args[i + 1]):
            return False
        seen.add(flag); i += 2
    return i == len(args) - 2 and args[i] == "--" and 0 < len(args[-1]) <= 100000 and "\x00" not in args[-1]


def clean(path):
    if not isinstance(path, str) or not path.startswith("/") or len(path) > 4096:
        return None
    if any(ord(c) < 32 or ord(c) == 127 for c in path):
        return None
    return os.path.normpath(path)


def read_small(path, limit):
    """A regular file's bytes up to `limit`, never through a final symlink; None otherwise."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            return None
        chunks, left = [], limit
        while left > 0:
            chunk = os.read(fd, min(left, 1024 * 1024))
            if not chunk:
                break
            chunks.append(chunk); left -= len(chunk)
        return b"".join(chunks)
    except OSError:
        return None
    finally:
        os.close(fd)


def folder_problem(path):
    """(real path, None) for a real directory owned by you, else (None, (code, message))."""
    if path is None:
        return None, ("folder", "Burro needs an absolute folder path.")
    real = os.path.realpath(path)
    try:
        info = os.stat(real)
    except OSError:
        return None, ("folder", "That folder doesn't exist on this machine.")
    if not stat.S_ISDIR(info.st_mode):
        return None, ("folder", "That path isn't a folder.")
    if info.st_uid != os.getuid():
        return None, ("folder", "That folder belongs to another user on this machine.")
    return real, None


def is_trusted(home, paths):
    data = read_small(os.path.join(home, ".claude.json"), MAX_CONFIG)
    try:
        projects = json.loads(data).get("projects") if data else None
    except (ValueError, AttributeError):
        projects = None
    if not isinstance(projects, dict):
        return False
    for start in paths:
        current = start
        while True:
            value = projects.get(current)
            if isinstance(value, dict) and value.get("hasTrustDialogAccepted") is True:
                return True
            parent = os.path.dirname(current)
            if parent == current:
                break
            current = parent
    return False


def login_shell():
    """Your login shell when it understands the fixed sh-style script, else /bin/sh."""
    try:
        shell = pwd.getpwuid(os.getuid()).pw_shell
    except KeyError:
        shell = ""
    if shell.startswith("/") and os.path.basename(shell) in SHELLS and os.access(shell, os.X_OK):
        return shell
    return "/bin/sh"


def run(argv, env, cwd, timeout, keep=64 * 1024):
    """Runs argv with output in a private temp file (never a pipe), stdin /dev/null and its own
    session. Returns (exit code or None on timeout, the last `keep` bytes of output as text)."""
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


def project_folder(cwd):
    return "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)


def check(handle, folder, agents_text, job_bytes, config):
    """The same reading as Burro's local start check. Returns (verdict, row, transcript facts)."""
    try:
        rows = json.loads(agents_text) if agents_text else []
        rows = [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []
    except ValueError:
        rows = []
    row = next((r for r in rows if r.get("id") == handle), None) or \
        next((r for r in rows if isinstance(r.get("sessionId"), str) and r["sessionId"].startswith(handle)), None)
    try:
        job = json.loads(job_bytes) if job_bytes else None
        job = job if isinstance(job, dict) else None
    except ValueError:
        job = None
    if row is None and job is None:
        return "pending", None, []
    session = next((v.lower() for v in ((row or {}).get("sessionId"), (job or {}).get("sessionId"))
                    if isinstance(v, str) and UUID.match(v)), None)
    cwd = next((v for v in ((row or {}).get("cwd"), (job or {}).get("cwd")) if isinstance(v, str)), folder)
    facts = []
    if session:
        exists = os.path.isfile(os.path.join(config, "projects", project_folder(cwd), session + ".jsonl"))
        facts.append(dict(cwd=cwd, session=session, exists=exists))
        if exists:
            return "started", row, facts
    state = next((v for v in ((row or {}).get("state"), (job or {}).get("state")) if isinstance(v, str)), "").lower()
    if state == "blocked":
        return "blocked", row, facts
    if state in ENDED:
        return "ended", row, facts
    return "pending", row, facts


def main():
    try:
        req = json.loads(base64.b64decode(REQUEST_B64))  # noqa: F821 (prepended by Burro)
    except (ValueError, TypeError):
        req = None
    if not isinstance(req, dict) or set(req) != {"op", "folder", "args"} or req.get("op") not in ("check", "start"):
        refuse()
    op, args = req["op"], req["args"]
    if op == "start" and not valid_args(args):
        refuse()
    if op == "check" and args != []:
        refuse()
    given = clean(req["folder"])
    folder, problem = folder_problem(given)
    if problem:
        done(ok=False, code=problem[0], error=problem[1])
    home = os.path.expanduser("~")
    path = os.pathsep.join([os.path.join(home, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "")])
    claude = shutil.which("claude", path=path)
    if not claude:
        done(ok=False, code="notInstalled", error="Claude Code isn't installed on this machine.")
    if not is_trusted(home, [folder, given]):
        done(ok=False, code="untrusted", folder=folder,
             error="Claude hasn't been trusted in this folder on this machine yet.")
    if op == "check":
        done(ok=True, op="check", folder=folder, trusted=True)

    env = {k: v for k, v in os.environ.items() if not (k.startswith("CLAUDE_CODE_") or k == "CLAUDECODE" or k.startswith("GIT_"))}
    env["PATH"] = path
    config = env.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    started_at = time.monotonic()
    code, output = run([login_shell(), "-lc", SCRIPT, "burro", folder, claude] + args, env, home, 60, keep=16 * 1024)
    if code == 70:
        done(ok=False, code="folder", error="That folder doesn't exist on this machine.")
    if "Workspace not trusted" in output:
        done(ok=False, code="untrusted", folder=folder, error="Claude hasn't been trusted in this folder on this machine yet.")
    match = HANDLE.search(output)
    if code != 0 or not match:
        lines = [l for l in output.splitlines() if l.strip()]
        reason = "it didn't answer in time" if code is None else (lines[-1][-300:] if lines else "unknown error")
        done(ok=False, code="failed", error="Claude didn't start: " + reason)
    handle = match.group(1)

    deadline = time.monotonic() + VERIFY_SECONDS
    verdict, row, facts, job_bytes = "pending", None, [], None
    while True:
        remaining = max(1.0, deadline - time.monotonic())
        _, agents = run([claude, "agents", "--json", "--all"], env, home, min(20.0, remaining + 5), keep=4 * 1024 * 1024)
        job_bytes = read_small(os.path.join(config, "jobs", handle, "state.json"), 64 * 1024)
        verdict, row, facts = check(handle, folder, agents, job_bytes, config)
        if verdict != "pending" or time.monotonic() >= deadline:
            break
        time.sleep(POLL_SECONDS)

    logs, discarded = "", False
    if verdict != "started":
        _, logs = run([claude, "logs", handle], env, home, 20, keep=16 * 1024)
        run([claude, "stop", handle], env, home, 20)
        run([claude, "rm", handle], env, home, 20)
        discarded = True
    done(ok=True, op="start", folder=folder, handle=handle, output=output[-4000:],
         agents=json.dumps([row]) if row is not None else "[]",
         job=job_bytes.decode("utf-8", "replace") if job_bytes else None,
         transcripts=facts, logs=logs, verdict=verdict, discarded=discarded,
         seconds=round(time.monotonic() - started_at, 1))


main()
