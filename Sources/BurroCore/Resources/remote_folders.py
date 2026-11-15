# Burro remote folder lister. Sent over SSH to a machine you added; Burro prepends one line,
# REQUEST_B64 = base64(JSON). Read-only: it opens a few files to read them and runs no program.
#   {"op": "list"}  the folders a new chat could start in: the projects in ~/.claude.json (with
#                   Claude's trust flag), working folders from the newest Codex state database and
#                   from Claude sessions of the last 30 days. For each: whether it exists, its git
#                   top level (found by reading `.git` as a folder or a file), branch from HEAD, and
#                   whether it is a linked worktree. At most 300 folders, within about 5 seconds.
#   {"op": "validate", "path": <absolute path>}  checks one typed folder: a real directory after
#                   resolving links, owned by you, and whether Claude has been trusted there.
# Prints one JSON object. Nothing else is accepted.
import base64, json, os, pathlib, re, sqlite3, stat, sys, time

LIMIT = 300
RECENT = 30 * 86400
DEADLINE = time.monotonic() + 5
MAX_CONFIG = 64 * 1024 * 1024
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def done(**fields):
    print(json.dumps(fields, ensure_ascii=True, allow_nan=False)); sys.exit(0)


def clean(path):
    """An absolute path of reasonable length with no control characters, or None."""
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


def claude_projects(home):
    """{folder: trusted} from ~/.claude.json."""
    data = read_small(os.path.join(home, ".claude.json"), MAX_CONFIG)
    try:
        projects = json.loads(data).get("projects") if data else None
    except (ValueError, AttributeError):
        projects = None
    if not isinstance(projects, dict):
        return {}
    result = {}
    for key, value in projects.items():
        path = clean(key)
        if path and len(result) < 5000:
            result[path] = isinstance(value, dict) and value.get("hasTrustDialogAccepted") is True
    return result


def trusted(path, projects):
    """Claude trusts a folder when it or a folder above it was accepted."""
    for candidate in {path, os.path.realpath(path)}:
        current = candidate
        while True:
            if projects.get(current) is True:
                return True
            parent = os.path.dirname(current)
            if parent == current:
                break
            current = parent
    return False


def codex_cwds(home):
    """{folder: last used} from the newest Codex state database, opened read-only."""
    folder = os.path.join(home, ".codex")
    try:
        names = [n for n in os.listdir(folder) if re.fullmatch(r"state_\d+\.sqlite", n)]
    except OSError:
        return {}
    if not names:
        return {}
    names.sort(key=lambda n: int(re.search(r"\d+", n).group()), reverse=True)
    path = os.path.join(folder, names[0])

    def query(immutable):
        uri = pathlib.Path(path).as_uri() + "?mode=ro" + ("&immutable=1" if immutable else "")
        db = sqlite3.connect(uri, uri=True, timeout=1)
        try:
            db.execute("PRAGMA query_only=ON")
            columns = {row[1] for row in db.execute("PRAGMA table_info(threads)")}
            where = " WHERE archived=0" if "archived" in columns else ""
            return list(db.execute("SELECT cwd, MAX(updated_at) FROM threads" + where +
                                   " GROUP BY cwd ORDER BY 2 DESC LIMIT " + str(LIMIT)))
        finally:
            db.close()

    try:
        try:
            rows = query(False)
        except sqlite3.OperationalError:
            # Read-only WAL mode may want to create absent sidecars; only a quiet checkpoint is read without them.
            if any(os.path.exists(path + s) for s in ("-wal", "-journal")):
                return {}
            rows = query(True)
    except (sqlite3.Error, OSError):
        return {}
    result = {}
    for cwd, updated in rows:
        path_value = clean(cwd)
        if path_value:
            try:
                result[path_value] = float(updated or 0)
            except (TypeError, ValueError):
                result[path_value] = 0.0
    return result


def claude_cwds(home, now):
    """{folder: last used} from Claude transcripts and session records of the last 30 days."""
    result = {}
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
    projects = os.path.join(config, "projects")
    try:
        folders = os.listdir(projects)[:2000]
    except OSError:
        folders = []
    for name in folders:
        if time.monotonic() > DEADLINE - 1.5:
            break
        directory = os.path.join(projects, name)
        newest, newest_time = None, 0.0
        try:
            with os.scandir(directory) as entries:
                for count, entry in enumerate(entries):
                    if count > 5000:
                        break
                    if not entry.name.endswith(".jsonl") or not UUID.match(entry.name[:-6]):
                        continue
                    info = entry.stat(follow_symlinks=False)
                    if stat.S_ISREG(info.st_mode) and info.st_mtime > newest_time:
                        newest, newest_time = entry.path, info.st_mtime
        except OSError:
            continue
        if not newest or now - newest_time > RECENT:
            continue
        try:
            fd = os.open(newest, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                head = os.read(fd, 64 * 1024)
            finally:
                os.close(fd)
        except OSError:
            continue
        for line in head.splitlines()[:50]:
            try:
                cwd = clean(json.loads(line).get("cwd"))
            except (ValueError, AttributeError):
                continue
            if cwd:
                result[cwd] = max(result.get(cwd, 0.0), newest_time)
                break
    sessions = os.path.join(config, "sessions")
    try:
        names = os.listdir(sessions)[:2000]
    except OSError:
        names = []
    for name in names:
        if time.monotonic() > DEADLINE - 1:
            break
        if not name.endswith(".json"):
            continue
        data = read_small(os.path.join(sessions, name), 1024 * 1024)
        try:
            record = json.loads(data) if data else None
            cwd = clean(record.get("cwd")) if isinstance(record, dict) else None
            updated = float(record.get("updatedAt", record.get("startedAt", 0))) / 1000 if cwd else 0
        except (ValueError, TypeError, AttributeError):
            continue
        if cwd and now - updated <= RECENT:
            result[cwd] = max(result.get(cwd, 0.0), updated)
    return result


def git_facts(path):
    """{root, branch, worktree} for the repository holding `path`, read from files only; None outside git."""
    current = path
    for _ in range(64):
        marker = os.path.join(current, ".git")
        try:
            info = os.lstat(marker)
        except OSError:
            info = None
        if info is not None:
            worktree = False
            if stat.S_ISDIR(info.st_mode):
                gitdir = marker
            elif stat.S_ISREG(info.st_mode):
                text = (read_small(marker, 4096) or b"").decode("utf-8", "replace").strip()
                if not text.startswith("gitdir:"):
                    return None
                gitdir = text[len("gitdir:"):].strip()
                if not gitdir.startswith("/"):
                    gitdir = os.path.normpath(os.path.join(current, gitdir))
                worktree = "/worktrees/" in gitdir
            else:
                return None
            head = (read_small(os.path.join(gitdir, "HEAD"), 1024) or b"").decode("utf-8", "replace").strip()
            branch = head[len("ref: refs/heads/"):] if head.startswith("ref: refs/heads/") else None
            if branch is not None and (len(branch) > 255 or any(ord(c) < 32 for c in branch)):
                branch = None
            return dict(root=current, branch=branch, worktree=worktree)
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent
    return None


def is_dir(path):
    try:
        return stat.S_ISDIR(os.stat(path).st_mode)
    except OSError:
        return False


def listing(home):
    now = time.time()
    projects = claude_projects(home)
    found = {}

    def add(path, source, used):
        entry = found.setdefault(path, dict(path=path, sources=[], lastUsed=None))
        if source not in entry["sources"]:
            entry["sources"].append(source)
        if used and (entry["lastUsed"] is None or used > entry["lastUsed"]):
            entry["lastUsed"] = used

    for path in projects:
        add(path, "claude", None)
    for path, used in codex_cwds(home).items():
        add(path, "codex", used)
    for path, used in claude_cwds(home, now).items():
        add(path, "claudeSession", used)
    ordered = sorted(found.values(), key=lambda e: (e["lastUsed"] is None, -(e["lastUsed"] or 0), e["path"]))
    folders, warnings = [], []
    for entry in ordered[:LIMIT]:
        if time.monotonic() > DEADLINE:
            warnings.append("Listing folders reached its time limit.")
            break
        exists = is_dir(entry["path"])
        entry.update(exists=exists, trusted=trusted(entry["path"], projects),
                     git=git_facts(entry["path"]) if exists else None)
        folders.append(entry)
    return dict(ok=True, version=1, folders=folders, truncated=len(ordered) > len(folders), warnings=warnings)


def validate(home, path):
    if path is None:
        done(ok=False, code="invalid", error="Enter an absolute folder path.")
    real = os.path.realpath(path)
    try:
        info = os.stat(real)
    except OSError:
        done(ok=False, code="missing", error="That folder doesn't exist on this machine.")
    if not stat.S_ISDIR(info.st_mode):
        done(ok=False, code="notDirectory", error="That path isn't a folder.")
    if info.st_uid != os.getuid():
        done(ok=False, code="notOwned", error="That folder belongs to another user on this machine.")
    projects = claude_projects(home)
    done(ok=True, version=1, path=real, trusted=trusted(real, projects) or trusted(path, projects), git=git_facts(real))


def main():
    try:
        req = json.loads(base64.b64decode(REQUEST_B64))  # noqa: F821 (prepended by Burro)
    except (ValueError, TypeError):
        req = None
    if not isinstance(req, dict):
        done(ok=False, code="invalid", error="Burro sent a request this machine won't run.")
    home = os.path.expanduser("~")
    op = req.get("op")
    if op == "list" and set(req) == {"op"}:
        done(**listing(home))
    if op == "validate" and set(req) == {"op", "path"}:
        validate(home, clean(req.get("path")))
    done(ok=False, code="invalid", error="Burro sent a request this machine won't run.")


main()
