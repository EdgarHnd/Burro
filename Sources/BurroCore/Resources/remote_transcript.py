# Burro remote chat reader. Sent over SSH to a machine you added; Burro prepends one validated
# line, REQUEST = {"provider": "codex"|"claude", "id": <uuid>, "limit": <int>}. Finds that chat's
# transcript under ~/.codex or ~/.claude, reads at most its last 16 MiB, and prints display
# messages as JSON. Read-only; writes nothing; same rules as Burro's local reader.
import json, os, re, sys

MAX_TAIL = 16 * 1024 * 1024
MAX_TEXT, MAX_TOOL, MAX_OUTPUT, MAX_TOTAL = 12000, 200, 600, 3 * 1024 * 1024
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

def clip(text, limit):
    text = "".join(c for c in text if c in "\n\t" or ord(c) >= 32)
    return text if len(text) <= limit else text[:limit] + "…"

def stamp(value):
    from datetime import datetime
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def embedded_command(code):
    # Codex's exec tool runs JavaScript like tools.exec_command({cmd:`...`}); show the command.
    start = code.find("cmd:")
    if start < 0: return None
    rest = code[start + 4:].lstrip()
    if not rest or rest[0] not in "`\"'": return None
    body = rest[1:]
    end = body.find(rest[0])
    body = body if end < 0 else body[:end]
    for line in re.split(r"[\n;]", body):
        line = line.replace("\\n", " ").strip()
        if line and not line.startswith("set -"): return line
    return None

def summary(name, value):
    text = ""
    if isinstance(value, str):
        try:
            parsed = json.loads(value)
            cmd = parsed.get("cmd") or parsed.get("command") if isinstance(parsed, dict) else None
            text = " ".join(cmd) if isinstance(cmd, list) else (cmd or value.splitlines()[0] if value else "")
        except Exception:
            text = embedded_command(value) or (value.splitlines()[0] if value else "")
    elif isinstance(value, dict):
        for key in ("command", "file_path", "path", "pattern", "description", "url", "query", "prompt", "id"):
            if isinstance(value.get(key), str):
                text = value[key]; break
        else:
            text = name
    return clip((text or name).splitlines()[0].strip() if (text or name) else name, MAX_TOOL)

def output_text(value):
    if isinstance(value, str): return value
    if isinstance(value, list):
        return "\n".join(i.get("text", "") if isinstance(i, dict) else str(i) for i in value)
    return ""

def find(provider, cid):
    home = os.path.expanduser("~")
    roots = [os.path.join(home, ".codex", "sessions"), os.path.join(home, ".codex", "archived_sessions")] if provider == "codex" \
        else [os.path.join(home, ".claude", "projects")]
    wanted = ("-" + cid + ".jsonl") if provider == "codex" else (cid + ".jsonl")
    visited = 0
    for root in roots:
        for dirpath, dirs, files in os.walk(root, followlinks=False):
            visited += len(files) + 1
            if visited > 20000: return None
            dirs[:] = [d for d in dirs if d != "subagents"]
            for name in files:
                if (provider == "codex" and name.endswith(wanted)) or (provider == "claude" and name == wanted):
                    path = os.path.join(dirpath, name)
                    if os.path.isfile(path) and not os.path.islink(path): return path
    return None

MAX_PLAN = 30

def plan_status(value):
    if value in ("completed", "complete", "done"): return "completed"
    if value in ("in_progress", "in-progress", "active", "running"): return "in_progress"
    return "pending"

def apply_plan(plan, name, value):
    """Keeps the running plan in step with TodoWrite and update_plan calls, like Burro's Rust reader."""
    if isinstance(value, str):
        try: value = json.loads(value)
        except Exception: value = None
    if not isinstance(value, dict): value = {}
    def items(raw, key):
        if not isinstance(raw, list): return None
        out = []
        for item in raw[:MAX_PLAN]:
            if not isinstance(item, dict): continue
            text = item.get(key) if isinstance(item.get(key), str) else item.get("content")
            if isinstance(text, str): out.append({"text": clip(text.strip(), 200), "status": plan_status(item.get("status"))})
        return out
    if name == "TodoWrite":
        new = items(value.get("todos"), "content")
        if new is not None: plan[:] = new
        return True
    if name != "update_plan": return False
    new = items(value.get("items"), "content")
    if new is None: new = items(value.get("plan"), "step")
    if new is not None:
        plan[:] = new
        return True
    if value.get("advance") is True:
        for item in plan:
            if item["status"] == "in_progress": item["status"] = "completed"; break
        for item in plan:
            if item["status"] == "pending": item["status"] = "in_progress"; break
    for done in value.get("done") or []:
        if isinstance(done, int) and 1 <= done <= len(plan): plan[done - 1]["status"] = "completed"
    start = value.get("start")
    if isinstance(start, int) and 1 <= start <= len(plan): plan[start - 1]["status"] = "in_progress"
    return True

def tool_message(name, short, value, plan, at):
    message = {"kind": "tool", "text": summary(name, value), "tool": clip(short, 80), "at": at}
    if isinstance(value, dict) and isinstance(value.get("description"), str):
        note = clip((value["description"].split("\n") or [""])[0].strip(), 120)
        if note: message["note"] = note
    if apply_plan(plan, short, value) and plan: message["plan"] = [dict(item) for item in plan]
    return message

def parse(data, provider):
    messages, calls, title, custom, cwd = [], {}, None, False, None
    plan, context = [], {}
    for raw in data.split(b"\n"):
        if not raw or len(raw) > 8 * 1024 * 1024: continue
        try: o = json.loads(raw)
        except Exception: continue
        at = stamp(o.get("timestamp")) if o.get("timestamp") else None
        if provider == "codex":
            p = o.get("payload") or {}
            if o.get("type") in ("turn_context", "session_meta"):
                if str(p.get("cwd", "")).startswith("/"): cwd = p["cwd"]
                continue
            if o.get("type") == "event_msg" and p.get("type") == "token_count":
                info = p.get("info") or {}
                last = info.get("last_token_usage") or {}
                tokens = last.get("total_tokens", last.get("input_tokens"))
                if isinstance(tokens, int): context["tokens"] = tokens
                if isinstance(info.get("model_context_window"), int): context["window"] = info["model_context_window"]
                continue
            if o.get("type") != "response_item": continue
            kind = p.get("type")
            if kind == "message" and p.get("role") in ("user", "assistant"):
                text = "\n".join(i.get("text", "") for i in p.get("content") or [] if isinstance(i, dict))
                if not text.strip(): continue
                if p["role"] == "user" and (text.lstrip().startswith("# AGENTS.md instructions") or text.lstrip().startswith("<")): continue
                messages.append({"kind": p["role"], "text": clip(text, MAX_TEXT), "at": at})
            elif kind in ("custom_tool_call", "function_call"):
                name = p.get("name") or "tool"
                if p.get("call_id"): calls[p["call_id"]] = len(messages)
                messages.append(tool_message(name, name, p.get("input") if p.get("input") is not None else p.get("arguments"), plan, at))
            elif kind in ("custom_tool_call_output", "function_call_output"):
                index = calls.get(p.get("call_id"))
                if index is not None: messages[index]["output"] = clip(output_text(p.get("output")).strip(), MAX_OUTPUT)
        else:
            if o.get("isSidechain"): continue
            if o.get("type") == "custom-title" and isinstance(o.get("customTitle"), str):
                title, custom = clip(o["customTitle"].strip(), 120), True; continue
            if o.get("type") == "ai-title" and not custom and isinstance(o.get("aiTitle"), str):
                title = clip(o["aiTitle"].strip(), 120); continue
            if str(o.get("cwd", "")).startswith("/"): cwd = o["cwd"]
            if o.get("isMeta"): continue
            content = (o.get("message") or {}).get("content")
            if o.get("type") == "user":
                if isinstance(content, str):
                    if content.strip() and not content.lstrip().startswith("<"):
                        messages.append({"kind": "user", "text": clip(content, MAX_TEXT), "at": at})
                elif isinstance(content, list):
                    for item in content:
                        if not isinstance(item, dict): continue
                        if item.get("type") == "tool_result":
                            index = calls.get(item.get("tool_use_id"))
                            if index is not None: messages[index]["output"] = clip(output_text(item.get("content")).strip(), MAX_OUTPUT)
                        elif item.get("type") == "text" and item.get("text", "").strip() and not item["text"].lstrip().startswith("<"):
                            messages.append({"kind": "user", "text": clip(item["text"], MAX_TEXT), "at": at})
            elif o.get("type") == "assistant" and isinstance(content, list):
                usage = (o.get("message") or {}).get("usage") or {}
                if isinstance(usage.get("input_tokens"), int):
                    context["tokens"] = sum(usage.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
                                            if isinstance(usage.get(k) or 0, int))
                for item in content:
                    if not isinstance(item, dict): continue
                    if item.get("type") == "text" and item.get("text", "").strip():
                        messages.append({"kind": "assistant", "text": clip(item["text"], MAX_TEXT), "at": at})
                    elif item.get("type") == "tool_use":
                        name = item.get("name") or "tool"
                        if item.get("id"): calls[item["id"]] = len(messages)
                        messages.append(tool_message(name, name.split("__")[-1], item.get("input"), plan, at))
    return messages, title, cwd, context

def main():
    req = REQUEST  # noqa: F821 (prepended by Burro)
    provider, cid, limit = req.get("provider"), str(req.get("id", "")), int(req.get("limit", 300))
    if provider not in ("codex", "claude") or not UUID.match(cid) or not 1 <= limit <= 500:
        print(json.dumps({"version": 1, "found": False, "error": "invalid request"})); return
    path = find(provider, cid)
    if not path:
        print(json.dumps({"version": 1, "found": False, "messages": [], "truncated": False})); return
    size = os.path.getsize(path)
    with open(path, "rb") as handle:
        offset = max(0, size - MAX_TAIL)
        handle.seek(offset)
        data = handle.read(MAX_TAIL)
    if offset:
        data = data[data.find(b"\n") + 1:] if b"\n" in data else b""
    messages, title, cwd, context = parse(data, provider)
    truncated = offset > 0 or len(messages) > limit
    messages = messages[-limit:]
    total, keep = 0, 0
    for index in range(len(messages) - 1, -1, -1):
        total += len(messages[index]["text"]) + len(messages[index].get("output", ""))
        if total > MAX_TOTAL:
            keep = index + 1; truncated = True; break
    messages = messages[keep:]
    print(json.dumps({"version": 1, "found": True, "messages": messages, "truncated": truncated, "title": title,
                      "cwd": cwd, "modified": os.path.getmtime(path),
                      "contextTokens": context.get("tokens"), "contextWindow": context.get("window")}))

main()
