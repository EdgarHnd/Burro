# Burro remote media reader. Sent over SSH to a machine you added; Burro prepends one line,
# REQUEST_B64 = base64(JSON {"path": <absolute path>, "max": <bytes>[, "op": "stat"]}). Only a
# regular image or video file within the size limit (judged after resolving links) is accepted.
# Without "op" it writes that file's bytes to stdout; with "op": "stat" it prints
# {"size", "mtime"} as JSON so Burro can tell whether its cached copy is still current. Read-only.
import base64, json, os, sys

IMAGES = {"png", "jpg", "jpeg", "gif", "webp", "heic"}
VIDEOS = {"mp4", "mov", "m4v", "webm"}

def fail(code, message):
    sys.stderr.write(message + "\n"); sys.exit(code)

def main():
    req = json.loads(base64.b64decode(REQUEST_B64))  # noqa: F821 (prepended by Burro)
    path, limit, op = req.get("path"), int(req.get("max", 0)), req.get("op")
    if not isinstance(path, str) or not path.startswith("/") or not 0 < limit <= 300 * 1024 * 1024 or op not in (None, "stat"):
        fail(2, "Invalid request.")
    real = os.path.realpath(path)
    ext = real.rsplit(".", 1)[-1].lower() if "." in os.path.basename(real) else ""
    if ext not in IMAGES | VIDEOS: fail(2, "Only images and videos are shown.")
    if not os.path.isfile(real): fail(4, "This file isn't there any more.")
    info = os.stat(real)
    if info.st_size > limit: fail(3, "This file is too large to show.")
    if op == "stat":
        print(json.dumps({"size": info.st_size, "mtime": info.st_mtime})); return
    out = sys.stdout.buffer
    with open(real, "rb") as handle:
        sent = 0
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk: break
            sent += len(chunk)
            if sent > limit: fail(3, "This file is too large to show.")
            out.write(chunk)
    out.flush()

main()
