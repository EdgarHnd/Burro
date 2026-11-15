//! One chat's conversation for Burro's in-app chat view: your messages, the agent's replies and
//! a short line per tool call (with the start of its output). A chat is found by id under the
//! provider roots, or given as a file inside an allowed root (Burro's cache of remote chats).
//! The parsed display messages of the last eight chats read are kept in memory with how far into
//! the file they go: a file that only grew is parsed from there, a replaced or shrunk file is
//! parsed again, and an untouched file answers `unchanged` when the app already holds that
//! revision. Raw bytes are never kept; an unfinished last line is simply read again next time.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::fd::{FromRawFd, OwnedFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const MAX_TAIL: u64 = 16 * 1024 * 1024;
const MAX_VISITED: usize = 20_000;
const MAX_TEXT: usize = 12_000;
const MAX_TOOL: usize = 200;
const MAX_OUTPUT: usize = 600;
const MAX_TOTAL: usize = 3 * 1024 * 1024;
const MAX_LINE: usize = 8 * 1024 * 1024;
/// Messages kept per chat: the largest `limit` a request may ask for.
const MAX_RETAINED: usize = 500;
/// Chats whose parse state is kept.
const MAX_STATES: usize = 8;
/// Folders below the allowed root a file request may name.
const MAX_DEPTH: usize = 8;
/// Bytes before the stopping point re-read to confirm the file was only appended to.
const TAIL_CHECK: usize = 4096;

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Request {
    pub provider: String,
    pub id: String,
    pub roots: Vec<String>,
    pub limit: usize,
    /// The revision the app already shows; an untouched chat at that revision answers `unchanged`.
    #[serde(default)]
    pub known: Option<u64>,
}

/// A transcript file at a given path, which must lie inside `root` (no symlinks below it, every
/// folder and the file owned by this user, a `.jsonl` file).
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct FileRequest {
    pub provider: String,
    pub path: String,
    pub root: String,
    pub limit: usize,
    #[serde(default)]
    pub known: Option<u64>,
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

#[derive(Serialize, Default, Debug, PartialEq)]
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
    /// Identifies this parse state; the same revision always describes the same messages.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<u64>,
    /// The chat is still at the revision the request named: `messages` is empty and the rest is omitted.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub unchanged: bool,
}

/// One chat's parse state: where in which file it stopped, and what it has gathered so far.
struct State {
    key: String,
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    /// Where in the file the parse began, and where the next read starts (after the last line parsed).
    base: u64,
    offset: u64,
    /// Length and hash of the bytes just before `offset`, checked before parsing on from there.
    tail_len: usize,
    tail_hash: u64,
    /// The parse began after the start of the file (it is longer than the 16 MiB read).
    head_cut: bool,
    parser: Parser,
    revision: u64,
}

pub(crate) struct Worker {
    locations: HashMap<String, PathBuf>,
    /// Least recently used first.
    states: Vec<State>,
    next_revision: u64,
}

impl Default for Worker {
    fn default() -> Self {
        // Revisions continue from the clock so a restarted worker never reuses one the app holds.
        let micros = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |d| d.as_micros() as u64);
        Self { locations: HashMap::new(), states: Vec::new(), next_revision: micros }
    }
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

/// Turns transcript lines into display messages, oldest first, and can be fed more lines later.
/// Feeding a file in pieces gives the same result as feeding it whole.
#[derive(Clone)]
pub(crate) struct Parser {
    codex: bool,
    /// Only the newest messages that any request could still show are kept (see `trim`).
    retain: bool,
    messages: Vec<Message>,
    /// Messages dropped from the front by `trim`; `calls` holds absolute positions.
    dropped: usize,
    plan: Vec<PlanItem>,
    context: Context,
    calls: HashMap<String, usize>,
    title: Option<String>,
    cwd: Option<String>,
    custom_title: bool,
}

impl Parser {
    pub(crate) fn new(provider: &str, retain: bool) -> Self {
        Self {
            codex: provider == "codex",
            retain,
            messages: Vec::new(),
            dropped: 0,
            plan: Vec::new(),
            context: Context::default(),
            calls: HashMap::new(),
            title: None,
            cwd: None,
            custom_title: false,
        }
    }

    fn push(&mut self, message: Message) {
        self.messages.push(message);
    }

    fn position(&self) -> usize {
        self.dropped + self.messages.len()
    }

    fn attach_output(&mut self, call: Option<&str>, output: &Value) {
        let Some(index) = call.and_then(|c| self.calls.get(c)).copied() else { return };
        if let Some(message) = index.checked_sub(self.dropped).and_then(|i| self.messages.get_mut(i)) {
            message.output = Some(clip(output_text(output).trim(), MAX_OUTPUT));
        }
    }

    /// Parses the complete lines in `bytes`, plus a last line without its newline when it is
    /// already a whole JSON object. Returns how many bytes were used; the rest is an unfinished
    /// line to read again once the file grows.
    pub(crate) fn feed(&mut self, bytes: &[u8]) -> usize {
        let mut used = 0;
        while used < bytes.len() {
            let rest = &bytes[used..];
            match rest.iter().position(|b| *b == b'\n') {
                Some(end) => {
                    self.line(&rest[..end]);
                    used += end + 1;
                }
                None => {
                    let complete = rest.len() <= MAX_LINE
                        && rest.first() == Some(&b'{')
                        && serde_json::from_slice::<Value>(rest).is_ok_and(|v| v.is_object());
                    if complete {
                        self.line(rest);
                        used = bytes.len();
                    }
                    break;
                }
            }
        }
        if self.retain {
            self.trim();
        }
        used
    }

    /// Drops the oldest messages that no request could show: past the largest limit, or past
    /// the response byte budget (outputs only ever grow, so a dropped message stays dropped).
    fn trim(&mut self) {
        let mut cut = self.messages.len().saturating_sub(MAX_RETAINED);
        let mut total = 0;
        if let Some(i) = self.messages[cut..].iter().rposition(|m| {
            total += m.text.len() + m.output.as_ref().map_or(0, String::len);
            total > MAX_TOTAL
        }) {
            cut += i + 1;
        }
        if cut > 0 {
            self.messages.drain(..cut);
            self.dropped += cut;
            let dropped = self.dropped;
            self.calls.retain(|_, index| *index >= dropped);
        }
    }

    fn line(&mut self, line: &[u8]) {
        if line.is_empty() || line.len() > MAX_LINE {
            return;
        }
        let Ok(object) = serde_json::from_slice::<Value>(line) else { return };
        let at = timestamp(&object["timestamp"]);
        if self.codex {
            self.codex_line(&object, at);
        } else {
            self.claude_line(&object, at);
        }
    }

    fn codex_line(&mut self, object: &Value, at: Option<f64>) {
        let payload = &object["payload"];
        if object["type"] == "turn_context" || object["type"] == "session_meta" {
            if let Some(path) = payload["cwd"].as_str().filter(|p| p.starts_with('/')) {
                self.cwd = Some(path.to_owned());
            }
            return;
        }
        if object["type"] == "event_msg" && payload["type"] == "token_count" {
            let info = &payload["info"];
            let last = &info["last_token_usage"];
            if let Some(tokens) = last["total_tokens"].as_u64().or_else(|| last["input_tokens"].as_u64()) {
                self.context.tokens = Some(tokens);
            }
            if let Some(window) = info["model_context_window"].as_u64() {
                self.context.window = Some(window);
            }
            return;
        }
        if object["type"] != "response_item" {
            return;
        }
        match payload["type"].as_str() {
            Some("message") => {
                let role = payload["role"].as_str().unwrap_or_default();
                if role != "user" && role != "assistant" {
                    return;
                }
                let text = payload["content"].as_array().map(|items| {
                    items
                        .iter()
                        .filter_map(|i| i["text"].as_str())
                        .collect::<Vec<_>>()
                        .join("\n")
                });
                let Some(text) = text.filter(|t| !t.trim().is_empty()) else { return };
                if role == "user" && injected(&text) {
                    return;
                }
                self.push(Message { kind: if role == "user" { "user" } else { "assistant" }, text: clip(&text, MAX_TEXT), at, ..Default::default() });
            }
            Some("custom_tool_call") | Some("function_call") => {
                let name = payload["name"].as_str().unwrap_or("tool").to_owned();
                let input = if payload["input"].is_null() { &payload["arguments"] } else { &payload["input"] };
                if let Some(call) = payload["call_id"].as_str() {
                    self.calls.insert(call.to_owned(), self.position());
                }
                let message = tool_message(&name, &name, input, &mut self.plan, at);
                self.push(message);
            }
            Some("custom_tool_call_output") | Some("function_call_output") => {
                self.attach_output(payload["call_id"].as_str(), &payload["output"]);
            }
            _ => {}
        }
    }

    fn claude_line(&mut self, object: &Value, at: Option<f64>) {
        if object["isSidechain"].as_bool() == Some(true) {
            return;
        }
        match object["type"].as_str() {
            Some("custom-title") => {
                if let Some(t) = object["customTitle"].as_str() {
                    self.title = Some(clip(t.trim(), 120));
                    self.custom_title = true;
                }
                return;
            }
            Some("ai-title") if !self.custom_title => {
                if let Some(t) = object["aiTitle"].as_str() {
                    self.title = Some(clip(t.trim(), 120));
                }
                return;
            }
            _ => {}
        }
        if let Some(path) = object["cwd"].as_str().filter(|p| p.starts_with('/')) {
            self.cwd = Some(path.to_owned());
        }
        if object["isMeta"].as_bool() == Some(true) {
            return;
        }
        let content = &object["message"]["content"];
        match object["type"].as_str() {
            Some("user") => match content {
                Value::String(text) if !text.trim().is_empty() && !text.trim_start().starts_with('<') => {
                    self.push(Message { kind: "user", text: clip(text, MAX_TEXT), at, ..Default::default() });
                }
                Value::Array(items) => {
                    for item in items {
                        if item["type"] == "tool_result" {
                            self.attach_output(item["tool_use_id"].as_str(), &item["content"]);
                        } else if item["type"] == "text" {
                            let text = item["text"].as_str().unwrap_or_default();
                            if !text.trim().is_empty() && !text.trim_start().starts_with('<') {
                                self.push(Message { kind: "user", text: clip(text, MAX_TEXT), at, ..Default::default() });
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
                    self.context.tokens = Some(input + part("cache_creation_input_tokens") + part("cache_read_input_tokens") + part("output_tokens"));
                }
                for item in content.as_array().into_iter().flatten() {
                    match item["type"].as_str() {
                        Some("text") => {
                            let text = item["text"].as_str().unwrap_or_default();
                            if !text.trim().is_empty() {
                                self.push(Message { kind: "assistant", text: clip(text, MAX_TEXT), at, ..Default::default() });
                            }
                        }
                        Some("tool_use") => {
                            let name = item["name"].as_str().unwrap_or("tool");
                            let short = name.rsplit("__").next().unwrap_or(name);
                            if let Some(id) = item["id"].as_str() {
                                self.calls.insert(id.to_owned(), self.position());
                            }
                            let message = tool_message(name, short, &item["input"], &mut self.plan, at);
                            self.push(message);
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }

    /// The newest `limit` messages within the byte budget, as a response.
    fn batch(&self, limit: usize, head_cut: bool) -> Batch {
        let start = self.messages.len().saturating_sub(limit);
        let mut messages = self.messages[start..].to_vec();
        let mut truncated = head_cut || self.dropped > 0 || start > 0;
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
        Batch {
            found: true,
            messages,
            truncated,
            title: self.title.clone(),
            cwd: self.cwd.clone(),
            context_tokens: self.context.tokens,
            context_window: self.context.window,
            ..Default::default()
        }
    }
}

/// Parses a transcript (whole file or its tail) into display messages, oldest first (tests compare against it).
#[cfg(test)]
pub(crate) fn parse(bytes: &[u8], provider: &str) -> (Vec<Message>, Option<String>, Option<String>, Context) {
    let mut parser = Parser::new(provider, false);
    parser.feed(bytes);
    (parser.messages, parser.title, parser.cwd, parser.context)
}

fn valid_request(provider: &str, limit: usize) -> bool {
    matches!(provider, "codex" | "claude") && (1..=MAX_RETAINED).contains(&limit)
}

/// A hash of the bytes just before where a parse stopped, so a rewrite under the same name is noticed.
fn fingerprint(bytes: &[u8]) -> u64 {
    use std::hash::Hasher;
    let mut hasher = std::hash::DefaultHasher::new();
    hasher.write(bytes);
    hasher.finish()
}

fn modified(meta: &fs::Metadata) -> f64 {
    meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9
}

/// Opens `path` for reading only if it lies inside `root`: each name below the root is opened
/// relative to its folder without following symlinks, every folder and the file must belong to
/// this user, and the file must be a regular `.jsonl` file.
fn open_within(root: &str, path: &str) -> io::Result<File> {
    let invalid = || io::Error::from(io::ErrorKind::InvalidInput);
    if !root.starts_with('/') || !path.starts_with('/') || root.len() > 4096 || path.len() > 4096 || root.contains('\0') || path.contains('\0') {
        return Err(invalid());
    }
    let rest = path.strip_prefix(root.trim_end_matches('/')).and_then(|r| r.strip_prefix('/')).ok_or_else(invalid)?;
    let names: Vec<&str> = rest.split('/').collect();
    if names.is_empty()
        || names.len() > MAX_DEPTH + 1
        || names.iter().any(|n| n.is_empty() || *n == "." || *n == "..")
        || !names.last().is_some_and(|n| n.len() > 6 && n.ends_with(".jsonl"))
    {
        return Err(invalid());
    }
    let owner = unsafe { libc::geteuid() };
    let check = |file: &File, directory: bool| -> io::Result<()> {
        let meta = file.metadata()?;
        let kind_ok = if directory { meta.is_dir() } else { meta.is_file() };
        if !kind_ok || meta.uid() != owner {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        Ok(())
    };
    let open_at = |folder: Option<&OwnedFd>, name: &str, flags: libc::c_int| -> io::Result<File> {
        let name = CString::new(name).map_err(|_| invalid())?;
        let fd = unsafe {
            match folder {
                Some(folder) => libc::openat(std::os::fd::AsRawFd::as_raw_fd(folder), name.as_ptr(), flags | libc::O_NOFOLLOW | libc::O_CLOEXEC),
                None => libc::open(name.as_ptr(), flags | libc::O_NOFOLLOW | libc::O_CLOEXEC),
            }
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    };
    let root_dir = open_at(None, root.trim_end_matches('/'), libc::O_RDONLY | libc::O_DIRECTORY)?;
    check(&root_dir, true)?;
    let mut folder = OwnedFd::from(root_dir);
    for name in &names[..names.len() - 1] {
        let next = open_at(Some(&folder), name, libc::O_RDONLY | libc::O_DIRECTORY)?;
        check(&next, true)?;
        folder = OwnedFd::from(next);
    }
    let file = open_at(Some(&folder), names[names.len() - 1], libc::O_RDONLY | libc::O_NONBLOCK)?;
    check(&file, false)?;
    Ok(file)
}

impl Worker {
    fn locate(&mut self, request: &Request) -> Option<PathBuf> {
        if let Some(path) = self.locations.get(&request.id).filter(|p| p.is_file()) {
            return Some(path.clone());
        }
        let wanted_codex = format!("-{}.jsonl", request.id);
        let wanted_claude = format!("{}.jsonl", request.id);
        // Entries carry the type their directory reported; only the roots and a match are stat'ed.
        let mut stack: Vec<(PathBuf, Option<fs::FileType>)> =
            request.roots.iter().map(|root| (PathBuf::from(root), None)).collect();
        let mut visited = 0;
        while let Some((path, known)) = stack.pop() {
            visited += 1;
            if visited > MAX_VISITED {
                return None;
            }
            let kind = match known {
                Some(kind) => kind,
                None => {
                    let Ok(meta) = fs::symlink_metadata(&path) else { continue };
                    meta.file_type()
                }
            };
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                if path.file_name().is_some_and(|n| n == "subagents") {
                    continue;
                }
                if let Ok(entries) = fs::read_dir(&path) {
                    stack.extend(entries.flatten().map(|e| {
                        let kind = e.file_type().ok();
                        (e.path(), kind)
                    }));
                }
                continue;
            }
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default();
            let hit = if request.provider == "codex" { name.ends_with(&wanted_codex) } else { name == wanted_claude };
            if hit && fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file()) {
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
        if !valid_request(&request.provider, request.limit)
            || !valid_id(&request.id)
            || request.roots.is_empty()
            || request.roots.len() > 3
            || request.roots.iter().any(|r| !Path::new(r).is_absolute() || r.len() > 4096)
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let Some(path) = self.locate(&request) else { return Ok(Batch::default()) };
        let file = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW).open(&path)?;
        let key = format!("{}:{}", request.provider, path.to_string_lossy());
        self.serve(key, file, &request.provider, request.limit, request.known)
    }

    pub(crate) fn read_file(&mut self, request: FileRequest) -> io::Result<Batch> {
        if !valid_request(&request.provider, request.limit) {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let file = match open_within(&request.root, &request.path) {
            Ok(file) => file,
            // A malformed request is a protocol error.
            Err(error) if error.kind() == io::ErrorKind::InvalidInput => return Err(error),
            // Missing, a symlink, someone else's, or not a regular file: nothing to show, and the
            // worker stays up for the next request.
            Err(_) => {
                self.states.retain(|s| !s.key.starts_with("file:") || !s.key.ends_with(&format!(":{}", request.path)));
                return Ok(Batch::default());
            }
        };
        let key = format!("file:{}:{}", request.provider, request.path);
        self.serve(key, file, &request.provider, request.limit, request.known)
    }

    /// Brings the chat's parse state up to date with the open file and answers from it.
    fn serve(&mut self, key: String, mut file: File, provider: &str, limit: usize, known: Option<u64>) -> io::Result<Batch> {
        let meta = file.metadata()?;
        if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } {
            self.states.retain(|s| s.key != key);
            return Err(io::ErrorKind::InvalidData.into());
        }
        let (device, inode, size) = (meta.dev(), meta.ino(), meta.len());
        let stamp = (meta.mtime(), meta.mtime_nsec());
        let previous = self.states.iter().position(|s| s.key == key).map(|i| self.states.remove(i));
        let current = match previous {
            Some(state) if state.device == device && state.inode == inode && state.size == size && state.modified == stamp => Some(state),
            Some(state) if state.device == device && state.inode == inode && size > state.size && size - state.offset <= MAX_TAIL => {
                self.advance(&mut file, state, size, stamp)?
            }
            _ => None,
        };
        let mut state = match current {
            Some(state) => state,
            None => {
                // New, replaced, shrunk or rewritten: parse the last 16 MiB from scratch.
                let start = size.saturating_sub(MAX_TAIL);
                file.seek(SeekFrom::Start(start))?;
                let mut bytes = Vec::new();
                (&mut file).take(MAX_TAIL).read_to_end(&mut bytes)?;
                let skip = if start > 0 { bytes.iter().position(|b| *b == b'\n').map_or(bytes.len(), |i| i + 1) } else { 0 };
                let mut parser = Parser::new(provider, true);
                let end = skip + parser.feed(&bytes[skip..]);
                let tail = &bytes[end - (end - skip).min(TAIL_CHECK)..end];
                State {
                    key: key.clone(),
                    device,
                    inode,
                    size,
                    modified: stamp,
                    base: start + skip as u64,
                    offset: start + end as u64,
                    tail_len: tail.len(),
                    tail_hash: fingerprint(tail),
                    head_cut: start > 0,
                    parser,
                    revision: self.next(),
                }
            }
        };
        let revision = state.revision;
        let batch = if known == Some(revision) {
            Batch { found: true, unchanged: true, revision: Some(revision), modified: Some(modified(&meta)), ..Default::default() }
        } else {
            Batch { revision: Some(revision), modified: Some(modified(&meta)), ..state.parser.batch(limit, state.head_cut) }
        };
        state.key = key;
        self.states.push(state);
        if self.states.len() > MAX_STATES {
            self.states.remove(0);
        }
        Ok(batch)
    }

    /// Parses what was appended to the same file since the state's last line. None when the
    /// bytes before that point are no longer the ones parsed (the file was rewritten).
    fn advance(&mut self, file: &mut File, mut state: State, size: u64, stamp: (i64, i64)) -> io::Result<Option<State>> {
        let from = state.offset - state.tail_len as u64;
        file.seek(SeekFrom::Start(from))?;
        let mut bytes = Vec::new();
        file.take(size - from).read_to_end(&mut bytes)?;
        if bytes.len() < state.tail_len || fingerprint(&bytes[..state.tail_len]) != state.tail_hash {
            return Ok(None);
        }
        let used = state.parser.feed(&bytes[state.tail_len..]);
        if used > 0 {
            let end = state.tail_len + used;
            state.offset += used as u64;
            let keep = ((state.offset - state.base) as usize).min(TAIL_CHECK);
            state.tail_len = keep;
            state.tail_hash = fingerprint(&bytes[end - keep..end]);
            state.revision = self.next();
        }
        state.size = size;
        state.modified = stamp;
        Ok(Some(state))
    }

    fn next(&mut self) -> u64 {
        self.next_revision += 1;
        self.next_revision
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
        let request = |limit| Request { provider: "claude".into(), id: id.into(), roots: vec![folder.0.join("claude").to_string_lossy().into()], limit, known: None };
        let batch = worker.read(request(4)).unwrap();
        assert!(batch.found && batch.truncated);
        assert_eq!(batch.messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), ["message 6", "message 7", "message 8", "message 9"]);
        let missing = worker.read(Request { id: "11111111-1111-1111-1111-111111111111".into(), ..request(4) }).unwrap();
        assert!(!missing.found);
        assert!(worker.read(Request { id: "../../etc/passwd".into(), ..request(4) }).is_err());
        assert!(worker.read(Request { provider: "other".into(), ..request(4) }).is_err());
    }

    fn file_request(root: &Path, path: &Path, provider: &str, limit: usize, known: Option<u64>) -> FileRequest {
        FileRequest { provider: provider.into(), path: path.to_string_lossy().into(), root: root.to_string_lossy().into(), limit, known }
    }

    /// The answer a fresh worker gives, without its revision.
    fn fresh(root: &Path, path: &Path, provider: &str, limit: usize) -> Batch {
        Batch { revision: None, ..Worker::default().read_file(file_request(root, path, provider, limit, None)).unwrap() }
    }

    fn append(path: &Path, bytes: &[u8]) {
        use std::io::Write;
        fs::OpenOptions::new().append(true).create(true).open(path).unwrap().write_all(bytes).unwrap();
    }

    fn claude_rows() -> Vec<Value> {
        vec![
            serde_json::json!({"type":"user","cwd":"/work/b","timestamp":"2026-11-09T01:00:00Z","message":{"content":"Rename the view"}}),
            serde_json::json!({"type":"assistant","message":{"usage":{"input_tokens":10},"content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test","description":"Run the tests"}}]}}),
            serde_json::json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"p1","name":"TodoWrite","input":{"todos":[{"content":"Read","status":"in_progress"}]}}]}}),
            serde_json::json!({"type":"ai-title","aiTitle":"Renaming"}),
            serde_json::json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"2 failing"}]}}),
            serde_json::json!({"type":"assistant","message":{"content":[{"type":"text","text":"Fixed — ünïcode ✓"}]}}),
            serde_json::json!({"type":"custom-title","customTitle":"Rename view"}),
            serde_json::json!({"type":"user","message":{"content":"Thanks"}}),
        ]
    }

    fn codex_rows() -> Vec<Value> {
        vec![
            serde_json::json!({"type":"session_meta","payload":{"cwd":"/work/app"}}),
            serde_json::json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the build"}]}}),
            serde_json::json!({"type":"response_item","payload":{"type":"function_call","name":"exec","call_id":"c1","arguments":"{\"cmd\":\"swift build\"}"}}),
            serde_json::json!({"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":4200},"model_context_window":272000}}}),
            serde_json::json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"Build complete"}}),
            serde_json::json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed."}]}}),
        ]
    }

    #[test]
    fn incremental_reads_equal_a_full_parse_for_any_split() {
        for (provider, rows) in [("claude", claude_rows()), ("codex", codex_rows())] {
            // The last line has no newline, as when a writer is mid-line or never ends the file.
            let bytes = lines(&rows);
            for step in [1, 7, 23, 64, 200, bytes.len()] {
                let folder = crate::tests::Fixture::new();
                let path = folder.0.join("chat.jsonl");
                fs::write(&path, b"").unwrap();
                let mut worker = Worker::default();
                let mut revisions = Vec::new();
                for chunk in bytes.chunks(step) {
                    append(&path, chunk);
                    let batch = worker.read_file(file_request(&folder.0, &path, provider, 50, None)).unwrap();
                    revisions.push(batch.revision.unwrap());
                    assert_eq!(Batch { revision: None, ..batch }, fresh(&folder.0, &path, provider, 50), "{provider} step {step}");
                }
                assert!(revisions.windows(2).all(|w| w[0] <= w[1]));
                let full = fresh(&folder.0, &path, provider, 50);
                let (messages, title, cwd, context) = parse(&bytes, provider);
                assert_eq!(full.messages, messages);
                assert_eq!((full.title, full.cwd, full.context_tokens, full.context_window), (title, cwd, context.tokens, context.window));
                assert!(full.messages.iter().any(|m| m.output.is_some()), "a later tool output reached its call");
            }
        }
    }

    #[test]
    fn unchanged_files_answer_unchanged_and_partial_lines_wait() {
        let folder = crate::tests::Fixture::new();
        let path = folder.0.join("chat.jsonl");
        let row = |text: &str| serde_json::json!({"type":"user","message":{"content":text}}).to_string();
        fs::write(&path, format!("{}\n{}", row("one"), &row("two")[..10])).unwrap();
        let mut worker = Worker::default();
        let first = worker.read_file(file_request(&folder.0, &path, "claude", 10, None)).unwrap();
        assert_eq!(first.messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), ["one"]);
        let revision = first.revision.unwrap();
        let same = worker.read_file(file_request(&folder.0, &path, "claude", 10, Some(revision))).unwrap();
        assert!(same.unchanged && same.found && same.messages.is_empty());
        assert_eq!(same.revision, Some(revision));
        // Without the revision the app gets the whole answer again, at the same revision.
        let again = worker.read_file(file_request(&folder.0, &path, "claude", 10, None)).unwrap();
        assert_eq!(again, first);
        // The rest of the unfinished line arrives.
        append(&path, format!("{}\n", &row("two")[10..]).as_bytes());
        let grown = worker.read_file(file_request(&folder.0, &path, "claude", 10, Some(revision))).unwrap();
        assert!(!grown.unchanged);
        assert!(grown.revision.unwrap() > revision);
        assert_eq!(grown.messages.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(), ["one", "two"]);
        // Junk that never becomes a line does not change the revision.
        append(&path, b"{\"type\":");
        let junk = worker.read_file(file_request(&folder.0, &path, "claude", 10, grown.revision)).unwrap();
        assert!(junk.unchanged);
    }

    #[test]
    fn replaced_truncated_and_rewritten_files_are_parsed_again() {
        let folder = crate::tests::Fixture::new();
        let path = folder.0.join("chat.jsonl");
        let rows = |texts: &[&str]| lines(&texts.iter().map(|t| serde_json::json!({"type":"user","message":{"content":t}})).collect::<Vec<_>>());
        let mut worker = Worker::default();
        let read = |worker: &mut Worker| Batch { revision: None, ..worker.read_file(file_request(&folder.0, &path, "claude", 10, None)).unwrap() };
        fs::write(&path, rows(&["a", "b", "c"])).unwrap();
        read(&mut worker);
        // Rotation: a new file under the same name.
        let other = folder.0.join("next.jsonl");
        fs::write(&other, rows(&["x", "y", "z", "w"])).unwrap();
        fs::rename(&other, &path).unwrap();
        assert_eq!(read(&mut worker), fresh(&folder.0, &path, "claude", 10));
        // Truncation in place.
        fs::write(&path, rows(&["q"])).unwrap();
        assert_eq!(read(&mut worker), fresh(&folder.0, &path, "claude", 10));
        // Rewritten in place to the same length, then grown: the byte check catches the rewrite.
        fs::write(&path, rows(&["m"])).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
        read(&mut worker);
        let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
        file.set_len(0).unwrap();
        drop(file);
        fs::write(&path, format!("{}\n", serde_json::json!({"type":"user","message":{"content":"n"}}))).unwrap();
        append(&path, rows(&["o"]).as_slice());
        assert_eq!(read(&mut worker), fresh(&folder.0, &path, "claude", 10));
    }

    #[test]
    fn retention_keeps_what_any_limit_can_show() {
        let folder = crate::tests::Fixture::new();
        let path = folder.0.join("chat.jsonl");
        let big = "x".repeat(MAX_TEXT);
        let mut rows = Vec::new();
        for i in 0..700 {
            rows.push(serde_json::json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":format!("t{i}"),"name":"Bash","input":{"command":format!("step {i}")}}]}}));
            if i % 3 == 0 {
                rows.push(serde_json::json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":format!("t{i}"),"content":"ok"}]}}));
            }
            if i % 50 == 0 {
                rows.push(serde_json::json!({"type":"assistant","message":{"content":[{"type":"text","text":big}]}}));
            }
        }
        // A result for a call far back, after many others.
        rows.push(serde_json::json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"late"}]}}));
        let bytes = lines(&rows);
        let mut worker = Worker::default();
        fs::write(&path, b"").unwrap();
        for chunk in bytes.chunks(bytes.len() / 9 + 1) {
            append(&path, chunk);
            for limit in [1, 300, 500] {
                worker.read_file(file_request(&folder.0, &path, "claude", limit, None)).unwrap();
            }
        }
        assert!(worker.states[0].parser.messages.len() <= MAX_RETAINED);
        for limit in [1, 37, 300, 500] {
            let incremental = Batch { revision: None, ..worker.read_file(file_request(&folder.0, &path, "claude", limit, None)).unwrap() };
            let mut whole = Parser::new("claude", false);
            whole.feed(&bytes);
            let expected = Batch { modified: incremental.modified, ..whole.batch(limit, false) };
            assert_eq!(incremental, expected, "limit {limit}");
            assert!(incremental.truncated);
        }
    }

    #[test]
    fn keeps_eight_chats() {
        let folder = crate::tests::Fixture::new();
        let mut worker = Worker::default();
        for i in 0..10 {
            let path = folder.0.join(format!("chat{i}.jsonl"));
            fs::write(&path, lines(&[serde_json::json!({"type":"user","message":{"content":"hi"}})])).unwrap();
            worker.read_file(file_request(&folder.0, &path, "claude", 10, None)).unwrap();
        }
        assert_eq!(worker.states.len(), MAX_STATES);
        assert!(worker.states[0].key.ends_with("chat2.jsonl"));
    }

    #[test]
    fn file_requests_stay_inside_the_root() {
        let folder = crate::tests::Fixture::new();
        let root = folder.0.join("cache");
        fs::create_dir_all(root.join("host/chats")).unwrap();
        let good = root.join("host/chats/a.jsonl");
        fs::write(&good, lines(&[serde_json::json!({"type":"user","message":{"content":"hi"}})])).unwrap();
        let outside = folder.0.join("outside.jsonl");
        fs::write(&outside, "{}").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("host/chats/link.jsonl")).unwrap();
        std::os::unix::fs::symlink(&folder.0, root.join("host/hop")).unwrap();
        fs::write(root.join("host/chats/notes.txt"), "{}").unwrap();
        fs::create_dir(root.join("host/chats/dir.jsonl")).unwrap();
        let mut worker = Worker::default();
        let mut ask = |path: PathBuf| worker.read_file(file_request(&root, &path, "claude", 10, None));
        assert_eq!(ask(good.clone()).unwrap().messages.len(), 1);
        // Refused files read as missing; malformed requests are errors.
        let refused = |result: io::Result<Batch>| result.is_ok_and(|b| !b.found && b.messages.is_empty());
        assert!(refused(ask(root.join("host/chats/missing.jsonl"))));
        assert!(refused(ask(root.join("host/chats/link.jsonl"))));
        assert!(refused(ask(root.join("host/hop/outside.jsonl"))));
        assert!(refused(ask(root.join("host/chats/dir.jsonl"))));
        assert!(ask(outside.clone()).is_err());
        assert!(ask(root.join("host/chats/../../outside.jsonl")).is_err());
        assert!(ask(root.join("host/./chats/a.jsonl")).is_err());
        assert!(ask(root.join("host/chats/notes.txt")).is_err());
        assert!(ask(PathBuf::from(format!("{}x/a.jsonl", root.display()))).is_err());
        assert!(worker.read_file(FileRequest { provider: "grok".into(), ..file_request(&root, &good, "claude", 10, None) }).is_err());
        assert!(worker.read_file(file_request(&root, &good, "claude", 501, None)).is_err());
        // A symlinked root is refused too.
        let linked = folder.0.join("linked");
        std::os::unix::fs::symlink(&root, &linked).unwrap();
        assert!(!worker.read_file(file_request(&linked, &linked.join("host/chats/a.jsonl"), "claude", 10, None)).unwrap().found);
        // A file replaced by a symlink after it was read is refused, and its state forgotten.
        fs::remove_file(&good).unwrap();
        std::os::unix::fs::symlink(&outside, &good).unwrap();
        assert!(!worker.read_file(file_request(&root, &good, "claude", 10, None)).unwrap().found);
        assert!(worker.states.iter().all(|s| !s.key.ends_with("a.jsonl")));
    }

    #[test]
    fn reads_by_id_share_the_incremental_state() {
        let folder = crate::tests::Fixture::new();
        let id = "01a1be01-5798-7cc1-9a11-57d9fc33c0da";
        let dir = folder.0.join("codex/2026/11/09");
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("rollout-2026-11-09T01-00-00-{id}.jsonl"));
        fs::write(&path, format!("{}\n", lines(&codex_rows()[..3]).iter().map(|b| *b as char).collect::<String>())).unwrap();
        let mut worker = Worker::default();
        let request = |known| Request { provider: "codex".into(), id: id.into(), roots: vec![folder.0.join("codex").to_string_lossy().into()], limit: 50, known };
        let first = worker.read(request(None)).unwrap();
        assert_eq!(first.messages.len(), 2);
        assert!(worker.read(request(first.revision)).unwrap().unchanged);
        append(&path, lines(&codex_rows()[3..]).as_slice());
        let grown = worker.read(request(first.revision)).unwrap();
        assert_eq!(grown.messages.len(), 3);
        assert_eq!(grown.messages[1].output.as_deref(), Some("Build complete"));
    }
}
