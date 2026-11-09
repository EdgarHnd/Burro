//! One chat's conversation for Burro's in-app chat view: your messages, the agent's replies and
//! a short line per tool call (with the start of its output). The file is found by chat id and
//! read fresh each time; only the id -> path location is cached, never message text.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const MAX_TAIL: u64 = 16 * 1024 * 1024;
const MAX_VISITED: usize = 20_000;
const MAX_TEXT: usize = 12_000;
const MAX_TOOL: usize = 200;
const MAX_OUTPUT: usize = 600;
const MAX_TOTAL: usize = 3 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Request {
    pub provider: String,
    pub id: String,
    pub roots: Vec<String>,
    pub limit: usize,
}

#[derive(Serialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Message {
    pub kind: &'static str,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub at: Option<f64>,
    /// The tool call's own one-line description, when it gave one (Claude's Bash and Agent do).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// For a plan update: the whole plan as it stands after it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan: Option<Vec<PlanItem>>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub(crate) struct PlanItem {
    pub text: String,
    /// "pending", "in_progress" or "completed".
    pub status: &'static str,
}

/// How much of the model's context the chat's latest turn used, when the log says.
#[derive(Default, Clone, Copy, Debug, PartialEq)]
pub(crate) struct Context {
    pub tokens: Option<u64>,
    pub window: Option<u64>,
}

#[derive(Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Batch {
    pub found: bool,
    pub messages: Vec<Message>,
    /// Older messages exist beyond what was returned.
    pub truncated: bool,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub modified: Option<f64>,
    pub context_tokens: Option<u64>,
    pub context_window: Option<u64>,
}

#[derive(Default)]
pub(crate) struct Worker {
    locations: HashMap<String, PathBuf>,
}

pub(crate) fn valid_id(id: &str) -> bool {
    id.len() == 36
        && id
            .chars()
            .enumerate()
            .all(|(i, c)| if [8, 13, 18, 23].contains(&i) { c == '-' } else { c.is_ascii_hexdigit() })
}

fn clip(text: &str, limit: usize) -> String {
    let clean: String = text.chars().filter(|c| !c.is_control() || *c == '\n' || *c == '\t').take(limit + 1).collect();
    if clean.chars().count() > limit {
        clean.chars().take(limit).collect::<String>() + "…"
    } else {
        clean
    }
}

fn timestamp(value: &Value) -> Option<f64> {
    let text = value.as_str().filter(|s| s.len() <= 64)?;
    let time = chrono::DateTime::parse_from_rfc3339(text).ok()?;
    Some(time.timestamp() as f64 + time.timestamp_subsec_nanos() as f64 / 1e9)
}

/// A one-line description of a tool call's input.
fn summary(name: &str, input: &Value) -> String {
    let field = |keys: &[&str]| keys.iter().find_map(|k| input.get(*k).and_then(Value::as_str).map(str::to_owned));
    let text = match input {
        Value::String(s) => serde_json::from_str::<Value>(s)
            .ok()
            .and_then(|v| v.get("cmd").or_else(|| v.get("command")).map(|c| match c {
                Value::String(s) => s.clone(),
                Value::Array(parts) => parts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "),
                _ => String::new(),
            }))
            .or_else(|| embedded_command(s))
            .unwrap_or_else(|| s.lines().next().unwrap_or_default().to_owned()),
        _ => field(&["command", "file_path", "path", "pattern", "description", "url", "query", "prompt", "id"])
            .unwrap_or_else(|| name.to_owned()),
    };
    clip(text.lines().next().unwrap_or_default().trim(), MAX_TOOL)
}

/// Codex's `exec` tool runs JavaScript such as ``tools.exec_command({cmd:`set -e\nswift build`})``;
/// show the shell command it runs, skipping `set -…` preambles.
fn embedded_command(code: &str) -> Option<String> {
    let start = code.find("cmd:")? + 4;
    let rest = code[start..].trim_start();
    let quote = rest.chars().next().filter(|c| matches!(c, '`' | '"' | '\''))?;
    let body = &rest[quote.len_utf8()..];
    let end = body.find(quote).unwrap_or(body.len());
    body[..end]
        .split(|c| c == '\n' || c == ';')
        .map(|line| line.replace("\\n", " ").trim().to_owned())
        .find(|line| !line.is_empty() && !line.starts_with("set -"))
}

fn output_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Array(items) => items
            .iter()
            .filter_map(|i| i.get("text").and_then(Value::as_str).or_else(|| i.as_str()))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn injected(text: &str) -> bool {
    let t = text.trim_start();
    t.starts_with("# AGENTS.md instructions") || t.starts_with('<')
}

const MAX_PLAN: usize = 30;

fn plan_status(value: &Value) -> &'static str {
    match value.as_str().unwrap_or_default() {
        "completed" | "complete" | "done" => "completed",
        "in_progress" | "in-progress" | "active" | "running" => "in_progress",
        _ => "pending",
    }
}

/// Applies a plan tool call to the running plan: Claude's TodoWrite, Codex's and the Claude app's
/// `update_plan` (whole lists, or the app's advance/done/start steps). False for other tools.
fn apply_plan(plan: &mut Vec<PlanItem>, name: &str, input: &Value) -> bool {
    let parsed;
    let input = match input {
        Value::String(s) => {
            parsed = serde_json::from_str::<Value>(s).unwrap_or(Value::Null);
            &parsed
        }
        other => other,
    };
    let list = |items: &Value, key: &str| -> Option<Vec<PlanItem>> {
        let items = items.as_array()?;
        Some(items.iter().take(MAX_PLAN).filter_map(|item| {
            let text = item[key].as_str().or_else(|| item["content"].as_str())?;
            Some(PlanItem { text: clip(text.trim(), 200), status: plan_status(&item["status"]) })
        }).collect())
    };
    match name {
        "TodoWrite" => {
            if let Some(items) = list(&input["todos"], "content") { *plan = items }
            true
        }
        "update_plan" => {
            if let Some(items) = list(&input["items"], "content").or_else(|| list(&input["plan"], "step")) {
                *plan = items;
            } else {
                if input["advance"].as_bool() == Some(true) {
                    if let Some(current) = plan.iter().position(|i| i.status == "in_progress") {
                        plan[current].status = "completed";
                    }
                    if let Some(next) = plan.iter().position(|i| i.status == "pending") {
                        plan[next].status = "in_progress";
                    }
                }
                for done in input["done"].as_array().into_iter().flatten().filter_map(Value::as_u64) {
                    if let Some(item) = (done as usize).checked_sub(1).and_then(|i| plan.get_mut(i)) { item.status = "completed" }
                }
                if let Some(start) = input["start"].as_u64() {
                    if let Some(item) = (start as usize).checked_sub(1).and_then(|i| plan.get_mut(i)) { item.status = "in_progress" }
                }
            }
            true
        }
        _ => false,
    }
}

fn tool_message(name: &str, short: &str, input: &Value, plan: &mut Vec<PlanItem>, at: Option<f64>) -> Message {
    let note = input.get("description").and_then(Value::as_str).map(|d| clip(d.lines().next().unwrap_or_default().trim(), 120))
        .filter(|d| !d.is_empty());
    let is_plan = apply_plan(plan, short, input);
    Message {
        kind: "tool",
        text: summary(name, input),
        tool: Some(clip(short, 80)),
        at,
        note,
        plan: if is_plan && !plan.is_empty() { Some(plan.clone()) } else { None },
        ..Default::default()
    }
}

/// Parses a transcript (whole file or its tail) into display messages, oldest first.
pub(crate) fn parse(bytes: &[u8], provider: &str) -> (Vec<Message>, Option<String>, Option<String>, Context) {
    let mut messages: Vec<Message> = Vec::new();
    let mut plan: Vec<PlanItem> = Vec::new();
    let mut context = Context::default();
    let mut calls: HashMap<String, usize> = HashMap::new();
    let (mut title, mut cwd): (Option<String>, Option<String>) = (None, None);
    let mut custom_title = false;
    for line in bytes.split(|b| *b == b'\n').filter(|l| !l.is_empty() && l.len() <= 8 * 1024 * 1024) {
        let Ok(object) = serde_json::from_slice::<Value>(line) else { continue };
        let at = timestamp(&object["timestamp"]);
        if provider == "codex" {
            let payload = &object["payload"];
            if object["type"] == "turn_context" || object["type"] == "session_meta" {
                if let Some(path) = payload["cwd"].as_str().filter(|p| p.starts_with('/')) {
                    cwd = Some(path.to_owned());
                }
                continue;
            }
            if object["type"] == "event_msg" && payload["type"] == "token_count" {
                let info = &payload["info"];
                let last = &info["last_token_usage"];
                if let Some(tokens) = last["total_tokens"].as_u64().or_else(|| last["input_tokens"].as_u64()) {
                    context.tokens = Some(tokens);
                }
                if let Some(window) = info["model_context_window"].as_u64() {
                    context.window = Some(window);
                }
                continue;
            }
            if object["type"] != "response_item" {
                continue;
            }
            match payload["type"].as_str() {
                Some("message") => {
                    let role = payload["role"].as_str().unwrap_or_default();
                    if role != "user" && role != "assistant" {
                        continue;
                    }
                    let text = payload["content"].as_array().map(|items| {
                        items
                            .iter()
                            .filter_map(|i| i["text"].as_str())
                            .collect::<Vec<_>>()
                            .join("\n")
                    });
                    let Some(text) = text.filter(|t| !t.trim().is_empty()) else { continue };
                    if role == "user" && injected(&text) {
                        continue;
                    }
                    messages.push(Message { kind: if role == "user" { "user" } else { "assistant" }, text: clip(&text, MAX_TEXT), at, ..Default::default() });
                }
                Some("custom_tool_call") | Some("function_call") => {
                    let name = payload["name"].as_str().unwrap_or("tool").to_owned();
                    let input = if payload["input"].is_null() { &payload["arguments"] } else { &payload["input"] };
                    if let Some(call) = payload["call_id"].as_str() {
                        calls.insert(call.to_owned(), messages.len());
                    }
                    messages.push(tool_message(&name, &name, input, &mut plan, at));
                }
                Some("custom_tool_call_output") | Some("function_call_output") => {
                    if let Some(index) = payload["call_id"].as_str().and_then(|c| calls.get(c)) {
                        if let Some(message) = messages.get_mut(*index) {
                            message.output = Some(clip(output_text(&payload["output"]).trim(), MAX_OUTPUT));
                        }
                    }
                }
                _ => {}
            }
        } else {
            if object["isSidechain"].as_bool() == Some(true) {
                continue;
            }
            match object["type"].as_str() {
                Some("custom-title") => {
                    if let Some(t) = object["customTitle"].as_str() {
                        title = Some(clip(t.trim(), 120));
                        custom_title = true;
                    }
                    continue;
                }
                Some("ai-title") if !custom_title => {
                    if let Some(t) = object["aiTitle"].as_str() {
                        title = Some(clip(t.trim(), 120));
                    }
                    continue;
                }
                _ => {}
            }
            if let Some(path) = object["cwd"].as_str().filter(|p| p.starts_with('/')) {
                cwd = Some(path.to_owned());
            }
            if object["isMeta"].as_bool() == Some(true) {
                continue;
            }
            let content = &object["message"]["content"];
            match object["type"].as_str() {
                Some("user") => match content {
                    Value::String(text) if !text.trim().is_empty() && !text.trim_start().starts_with('<') => {
                        messages.push(Message { kind: "user", text: clip(text, MAX_TEXT), at, ..Default::default() });
                    }
                    Value::Array(items) => {
                        for item in items {
                            if item["type"] == "tool_result" {
                                if let Some(index) = item["tool_use_id"].as_str().and_then(|c| calls.get(c)) {
                                    if let Some(message) = messages.get_mut(*index) {
                                        message.output = Some(clip(output_text(&item["content"]).trim(), MAX_OUTPUT));
                                    }
                                }
                            } else if item["type"] == "text" {
                                let text = item["text"].as_str().unwrap_or_default();
                                if !text.trim().is_empty() && !text.trim_start().starts_with('<') {
                                    messages.push(Message { kind: "user", text: clip(text, MAX_TEXT), at, ..Default::default() });
                                }
                            }
                        }
                    }
                    _ => {}
                },
                Some("assistant") => {
                    let usage = &object["message"]["usage"];
                    if let Some(input) = usage["input_tokens"].as_u64() {
                        let part = |key: &str| usage[key].as_u64().unwrap_or(0);
                        context.tokens = Some(input + part("cache_creation_input_tokens") + part("cache_read_input_tokens") + part("output_tokens"));
                    }
                    for item in content.as_array().into_iter().flatten() {
                        match item["type"].as_str() {
                            Some("text") => {
                                let text = item["text"].as_str().unwrap_or_default();
                                if !text.trim().is_empty() {
                                    messages.push(Message { kind: "assistant", text: clip(text, MAX_TEXT), at, ..Default::default() });
                                }
                            }
                            Some("tool_use") => {
                                let name = item["name"].as_str().unwrap_or("tool");
                                let short = name.rsplit("__").next().unwrap_or(name);
                                if let Some(id) = item["id"].as_str() {
                                    calls.insert(id.to_owned(), messages.len());
                                }
                                messages.push(tool_message(name, short, &item["input"], &mut plan, at));
                            }
                            _ => {}
                        }
                    }
                }
                _ => {}
            }
        }
    }
    (messages, title, cwd, context)
}

impl Worker {
    fn locate(&mut self, request: &Request) -> Option<PathBuf> {
        if let Some(path) = self.locations.get(&request.id).filter(|p| p.is_file()) {
            return Some(path.clone());
        }
        let wanted_codex = format!("-{}.jsonl", request.id);
        let wanted_claude = format!("{}.jsonl", request.id);
        let mut stack: Vec<PathBuf> = request.roots.iter().map(PathBuf::from).collect();
        let mut visited = 0;
        while let Some(path) = stack.pop() {
            visited += 1;
            if visited > MAX_VISITED {
                return None;
            }
            let Ok(meta) = fs::symlink_metadata(&path) else { continue };
            if meta.is_symlink() {
                continue;
            }
            if meta.is_dir() {
                if path.file_name().is_some_and(|n| n == "subagents") {
                    continue;
                }
                if let Ok(entries) = fs::read_dir(&path) {
                    stack.extend(entries.flatten().map(|e| e.path()));
                }
                continue;
            }
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
            let hit = if request.provider == "codex" { name.ends_with(&wanted_codex) } else { name == wanted_claude };
            if hit && meta.is_file() {
                self.locations.insert(request.id.clone(), path.clone());
                if self.locations.len() > 2048 {
                    self.locations.clear();
                }
                return Some(path);
            }
        }
        None
    }

    pub(crate) fn read(&mut self, request: Request) -> io::Result<Batch> {
        if !matches!(request.provider.as_str(), "codex" | "claude")
            || !valid_id(&request.id)
            || request.roots.is_empty()
            || request.roots.len() > 3
            || request.roots.iter().any(|r| !Path::new(r).is_absolute() || r.len() > 4096)
            || !(1..=500).contains(&request.limit)
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let Some(path) = self.locate(&request) else { return Ok(Batch::default()) };
        let mut file = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW).open(&path)?;
        let meta = file.metadata()?;
        if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let offset = meta.len().saturating_sub(MAX_TAIL);
        file.seek(SeekFrom::Start(offset))?;
        let mut bytes = Vec::new();
        file.take(MAX_TAIL).read_to_end(&mut bytes)?;
        if offset > 0 {
            let start = bytes.iter().position(|b| *b == b'\n').map_or(bytes.len(), |i| i + 1);
            bytes.drain(..start);
        }
        let (mut messages, title, cwd, context) = parse(&bytes, &request.provider);
        let mut truncated = offset > 0;
        if messages.len() > request.limit {
            messages.drain(..messages.len() - request.limit);
            truncated = true;
        }
        // Keep the response bounded: drop the oldest messages past the byte budget.
        let mut total = 0;
        let keep_from = messages
            .iter()
            .rposition(|m| {
                total += m.text.len() + m.output.as_ref().map_or(0, String::len);
                total > MAX_TOTAL
            })
            .map_or(0, |i| i + 1);
        if keep_from > 0 {
            messages.drain(..keep_from);
            truncated = true;
        }
        Ok(Batch {
            found: true,
            messages,
            truncated,
            title,
            cwd,
            modified: Some(meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9),
            context_tokens: context.tokens,
            context_window: context.window,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn lines(values: &[Value]) -> Vec<u8> {
        values.iter().map(|v| v.to_string()).collect::<Vec<_>>().join("\n").into_bytes()
    }

    #[test]
    fn codex_messages_tools_and_outputs_skip_injected_context() {
        let bytes = lines(&[
            serde_json::json!({"type":"turn_context","payload":{"cwd":"/work/app"}}),
            serde_json::json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /work"}]}}),
            serde_json::json!({"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"system"}]}}),
            serde_json::json!({"type":"response_item","timestamp":"2026-11-09T01:00:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the build"}]}}),
            serde_json::json!({"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1","input":"{\"cmd\":\"swift build\"}"}}),
            serde_json::json!({"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Build complete"}]}}),
            serde_json::json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed."}]}}),
        ]);
        let (messages, _, cwd, _) = parse(&bytes, "codex");
        let shape: Vec<_> = messages.iter().map(|m| (m.kind, m.text.as_str(), m.output.as_deref())).collect();
        assert_eq!(shape, [("user", "Fix the build", None), ("tool", "swift build", Some("Build complete")), ("assistant", "Fixed.", None)]);
        assert_eq!(cwd.as_deref(), Some("/work/app"));
        assert!(messages[0].at.is_some());
    }

    #[test]
    fn codex_exec_javascript_shows_the_shell_command() {
        assert_eq!(embedded_command("const r=await tools.exec_command({cmd:`set -e\nrg -n foo src`})").as_deref(), Some("rg -n foo src"));
        assert_eq!(embedded_command("text(await tools.exec_command({cmd:\"set -euo pipefail; swift test\"}))").as_deref(), Some("swift test"));
        assert_eq!(embedded_command("// @exec: {\"yield_time_ms\": 1000}"), None);
        assert_eq!(summary("exec", &Value::String("text(await tools.exec_command({cmd:`git status`}))".into())), "git status");
    }

    #[test]
    fn claude_text_tool_use_and_results_with_title() {
        let bytes = lines(&[
            serde_json::json!({"type":"user","cwd":"/work/b","message":{"content":"Rename the view"}}),
            serde_json::json!({"type":"user","isMeta":true,"message":{"content":"Caveat"}}),
            serde_json::json!({"type":"assistant","message":{"id":"m1","content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/work/b/View.swift"}}]}}),
            serde_json::json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"Edited"}]}}),
            serde_json::json!({"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"Renamed."}]}}),
            serde_json::json!({"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"worker"}]}}),
            serde_json::json!({"type":"custom-title","customTitle":"Rename view"}),
        ]);
        let (messages, title, _, _) = parse(&bytes, "claude");
        let shape: Vec<_> = messages.iter().map(|m| (m.kind, m.text.as_str(), m.tool.as_deref(), m.output.as_deref())).collect();
        assert_eq!(shape, [("user", "Rename the view", None, None), ("tool", "/work/b/View.swift", Some("Edit"), Some("Edited")), ("assistant", "Renamed.", None, None)]);
        assert_eq!(title.as_deref(), Some("Rename view"));
    }

    #[test]
    fn plans_descriptions_and_context() {
        let bytes = lines(&[
            serde_json::json!({"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"output_tokens":5},"content":[
                {"type":"tool_use","id":"p1","name":"mcp__ccd_turn__update_plan","input":{"items":[{"content":"Read","status":"in_progress"},{"content":"Fix","status":"pending"}]}},
                {"type":"tool_use","id":"b1","name":"Bash","input":{"command":"swift test","description":"Run the tests"}},
                {"type":"tool_use","id":"p2","name":"mcp__ccd_turn__update_plan","input":{"advance":true}}]}}),
        ]);
        let (messages, _, _, context) = parse(&bytes, "claude");
        fn plan(m: &Message) -> Option<Vec<(String, &'static str)>> {
            m.plan.as_ref().map(|p| p.iter().map(|i| (i.text.clone(), i.status)).collect())
        }
        let owned = |items: &[(&str, &'static str)]| Some(items.iter().map(|(t, s)| (t.to_string(), *s)).collect::<Vec<_>>());
        assert_eq!(plan(&messages[0]), owned(&[("Read", "in_progress"), ("Fix", "pending")]));
        assert_eq!(messages[1].note.as_deref(), Some("Run the tests"));
        assert_eq!(messages[1].plan, None);
        assert_eq!(plan(&messages[2]), owned(&[("Read", "completed"), ("Fix", "in_progress")]));
        assert_eq!(context.tokens, Some(1015));

        let codex = lines(&[
            serde_json::json!({"type":"response_item","payload":{"type":"function_call","name":"update_plan","call_id":"u","arguments":"{\"plan\":[{\"step\":\"Ship\",\"status\":\"completed\"}]}"}}),
            serde_json::json!({"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":4200},"model_context_window":272000}}}),
        ]);
        let (messages, _, _, context) = parse(&codex, "codex");
        assert_eq!(plan(&messages[0]), owned(&[("Ship", "completed")]));
        assert_eq!(context, Context { tokens: Some(4200), window: Some(272000) });
    }

    #[test]
    fn reads_by_id_with_limits_and_rejects_bad_requests() {
        let folder = crate::tests::Fixture::new();
        let id = "01a1be01-5798-7cc1-9a11-57d9fc33c0da";
        let dir = folder.0.join("claude/proj");
        fs::create_dir_all(dir.join(format!("{id}/subagents"))).unwrap();
        let rows: Vec<Value> = (0..10).map(|i| serde_json::json!({"type":"user","message":{"content":format!("message {i}")}})).collect();
        fs::write(dir.join(format!("{id}.jsonl")), lines(&rows)).unwrap();
        fs::write(dir.join(format!("{id}/subagents/{id}.jsonl")), "{}").unwrap();
        let mut worker = Worker::default();
        let request = |limit| Request { provider: "claude".into(), id: id.into(), roots: vec![folder.0.join("claude").to_string_lossy().into()], limit };
        let batch = worker.read(request(4)).unwrap();
        assert!(batch.found && batch.truncated);
        assert_eq!(batch.messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), ["message 6", "message 7", "message 8", "message 9"]);
        let missing = worker.read(Request { id: "11111111-1111-1111-1111-111111111111".into(), ..request(4) }).unwrap();
        assert!(!missing.found);
        assert!(worker.read(Request { id: "../../etc/passwd".into(), ..request(4) }).is_err());
        assert!(worker.read(Request { provider: "other".into(), ..request(4) }).is_err());
    }
}
