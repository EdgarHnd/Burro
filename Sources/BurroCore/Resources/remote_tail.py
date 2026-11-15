# Burro remote transcript tail. Sent over SSH to a machine you added; Burro prepends one line,
# REQUEST_B64 = base64(JSON {"provider": "codex"|"claude", "id": <uuid>, "pathHint"?: <path>,
# "have"?: {"dev", "ino", "start", "end", "headHash"}, "initial": <bytes>, "cap": <bytes>,
# "earlier"?: <bytes>}). Finds that chat's transcript file under ~/.claude/projects,
# ~/.codex/sessions or ~/.codex/archived_sessions (a path hint counts only when its real path lies
# under one of those and its name matches the id) and sends raw bytes of it so Burro can keep a copy:
#   - the copy Burro has is still a prefix-aligned slice of the same file (same device and inode,
#     the file at least as long, the first 4 KB of the slice unchanged): "append" with the bytes
#     after it, up to `cap`, ending at a line end; nothing at all when the file didn't grow;
#   - with "earlier": "prepend" with up to that many bytes before the slice, starting at a line
#     start, never making the copy longer than 16 MiB;
#   - otherwise (a new file, rotated, truncated or rewritten): "reset" with the last `initial`
#     bytes, starting and ending at a line boundary.
# Output: one JSON header line {mode, path, dev, ino, start, end, size, mtime, count} followed by
# exactly `count` raw bytes ("path" is left out when it equals the hint) ("missing" or "error" headers carry no bytes). Read-only: it opens one
# file for reading, runs nothing, writes nothing and never echoes anything from the request.
import base64, hashlib, json, os, re, stat, sys

MiB = 1024 * 1024
MAX_WINDOW = 4 * MiB          # largest `initial` / `cap`
MAX_TOTAL = 16 * MiB          # largest copy "earlier" may build
HEAD = 4096                   # bytes hashed at the start of the copy
MAX_VISITED = 20000
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HEX = re.compile(r"^[0-9a-f]{64}$")

def reply(header, body=b""):
    header["count"] = len(body)
    out = sys.stdout.buffer
    out.write(json.dumps(header, separators=(",", ":")).encode() + b"\n")
    out.write(body)
    out.flush()

def number(value, low, high):
    return type(value) is int and low <= value <= high

def parse_request(raw):
    req = json.loads(base64.b64decode(raw, validate=True))
    if not isinstance(req, dict): return None
    provider, cid = req.get("provider"), req.get("id")
    if provider not in ("codex", "claude") or not isinstance(cid, str) or not UUID.match(cid): return None
    initial, cap, earlier = req.get("initial", MAX_WINDOW), req.get("cap", MAX_WINDOW), req.get("earlier", 0)
    if not number(initial, 1, MAX_WINDOW) or not number(cap, 1, MAX_WINDOW) or not number(earlier, 0, MAX_TOTAL): return None
    hint = req.get("pathHint")
    if hint is not None and not (isinstance(hint, str) and hint.startswith("/") and len(hint) <= 4096 and "\0" not in hint): return None
    have = req.get("have")
    if have is not None:
        if not isinstance(have, dict): return None
        if not all(number(have.get(k), 0, 1 << 62) for k in ("dev", "ino", "start", "end")): return None
        if have["start"] > have["end"] or not (isinstance(have.get("headHash"), str) and HEX.match(have["headHash"])): return None
    return provider, cid, hint, have, initial, cap, earlier

def roots(provider):
    home = os.path.expanduser("~")
    names = [(".codex", "sessions"), (".codex", "archived_sessions")] if provider == "codex" else [(".claude", "projects")]
    result = []
    for parts in names:
        real = os.path.realpath(os.path.join(home, *parts))
        if os.path.isdir(real): result.append(real)
    return result

def named(provider, cid, name):
    return name == cid + ".jsonl" if provider == "claude" else name.endswith("-" + cid + ".jsonl")

def confined(provider, cid, path, real_roots):
    """The real path of `path` when it is a regular file under a provider root named for this chat."""
    try:
        if os.path.islink(path): return None
        real = os.path.realpath(path)
    except (OSError, ValueError):
        return None
    if not any(real.startswith(root + os.sep) for root in real_roots): return None
    if not named(provider, cid, os.path.basename(real)) or not os.path.isfile(real): return None
    return real

def find(provider, cid, real_roots):
    visited = 0
    for root in real_roots:
        for dirpath, dirs, files in os.walk(root, followlinks=False):
            visited += len(files) + 1
            if visited > MAX_VISITED: return None
            dirs[:] = [d for d in dirs if d != "subagents"]
            for name in files:
                if named(provider, cid, name):
                    real = confined(provider, cid, os.path.join(dirpath, name), real_roots)
                    if real: return real
    return None

def read_at(fd, offset, length):
    chunks, done = [], 0
    while done < length:
        chunk = os.pread(fd, min(length - done, MiB), offset + done)
        if not chunk: break
        chunks.append(chunk); done += len(chunk)
    return b"".join(chunks)

def main():
    try:
        request = parse_request(REQUEST_B64)  # noqa: F821 (prepended by Burro)
    except Exception:
        request = None
    if request is None:
        reply({"mode": "error", "error": "invalid request"}); return
    provider, cid, hint, have, initial, cap, earlier = request
    real_roots = roots(provider)
    path = (confined(provider, cid, hint, real_roots) if hint else None) or find(provider, cid, real_roots)
    if not path:
        reply({"mode": "missing"}); return
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        reply({"mode": "missing"}); return
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            reply({"mode": "missing"}); return
        size = info.st_size
        base = {"dev": info.st_dev, "ino": info.st_ino, "size": size, "mtime": info.st_mtime}
        if path != hint: base["path"] = path  # unchanged paths aren't repeated: a no-growth reply stays tiny
        same = have is not None and have["dev"] == info.st_dev and have["ino"] == info.st_ino and size >= have["end"] \
            and hashlib.sha256(read_at(fd, have["start"], min(HEAD, have["end"] - have["start"]))).hexdigest() == have["headHash"]
        if same and earlier:
            want = max(0, min(earlier, MAX_TOTAL - (have["end"] - have["start"]), have["start"]))
            start = have["start"] - want
            data = read_at(fd, start, want)
            if start > 0:
                cut = data.find(b"\n")
                data = data[cut + 1:] if cut >= 0 else b""
                start = have["start"] - len(data)
            reply(dict(base, mode="prepend", start=start, end=have["end"]), data)
        elif same:
            data = read_at(fd, have["end"], min(size - have["end"], cap))
            if data and not data.endswith(b"\n"):
                cut = data.rfind(b"\n")
                # A line still being written waits for its end, unless it alone fills the window.
                data = data[:cut + 1] if cut >= 0 else (data if len(data) >= cap else b"")
            reply(dict(base, mode="append", start=have["start"], end=have["end"] + len(data)), data)
        else:
            start = max(0, size - initial)
            data = read_at(fd, start, size - start)
            if start > 0:
                cut = data.find(b"\n")
                data = data[cut + 1:] if cut >= 0 else b""
                start = size - len(data) if data else size
            cut = data.rfind(b"\n")
            data = data[:cut + 1] if cut >= 0 else b""
            reply(dict(base, mode="reset", start=start, end=start + len(data)), data)
    except Exception:
        reply({"mode": "error", "error": "read failed"})
    finally:
        os.close(fd)

main()
