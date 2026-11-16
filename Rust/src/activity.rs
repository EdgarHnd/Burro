//! One day of agent activity for Burro's Today page: your turns and the agents' replies per
//! hour, explicit questions agents asked you, per-chat counts, and per chat the stretches the
//! agent was active that day. A stretch joins consecutive transcript events (your messages,
//! replies, tool calls and their results) less than 5 minutes apart, and also joins across a longer
//! quiet gap while the turn was still owing something (a long tool call or generation; Codex:
//! started and not completed; Claude: the last main-chain line is your message awaiting a reply or
//! a tool call awaiting its result), up to 30 minutes per gap; a longer gap splits, since it may
//! be a wait for your approval rather than work. A gap that starts while the agent waits on you
//! never joins: Codex `approval_required` and `request_user_input` (event or tool call), Claude
//! `AskUserQuestion` and `ExitPlanMode` tool calls. Claude's permission prompts aren't written to
//! the transcript, so for them the 30-minute cap is the only rule; a waiting chat isn't running.
//! Claude local command lines (`<command-name>`, `<local-command-stdout>` and the like) and compact
//! summaries owe nothing; a line with only thinking changes nothing. A turn still running when
//! the file was read extends its last stretch to now, unless the file has been quiet for
//! more than 15 minutes. Stretches are clipped to the day and bounded (300 per chat, 20,000 per
//! answer; past that a chat's are left out and the answer is partial). The cache keeps only
//! timestamps, kinds, merged stretches and folders per file, never conversation text. Optional
//! last-reply previews are read fresh from each file's tail and returned, not cached.
use crate::Stamp;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const MAX_FILE: u64 = 32 * 1024 * 1024;
/// Huge, long-running transcripts are read from the end: lines are chronological, so the
/// newest 32 MiB usually covers the day. If it doesn't, the batch is marked partial.
const MAX_TAIL: u64 = 32 * 1024 * 1024;
const MAX_BYTES: u64 = 256 * 1024 * 1024;
const MAX_VISITED: usize = 20_000;
const MAX_SESSIONS: usize = 500;
const MAX_PREVIEWS: usize = 120;
const PREVIEW_TAIL: u64 = 256 * 1024;
const PREVIEW_CHARS: usize = 160;
const MAX_PATH: usize = 4096;
/// Transcript events closer than this are one stretch of agent activity.
const ACTIVE_GAP: f64 = 300.0;
/// A quiet gap inside a turn that was still owing something joins the stretch up to this long.
const MAX_BRIDGE: f64 = 30.0 * 60.0;
/// A running turn extends to now only while the file was written this recently.
const RUNNING_QUIET: f64 = 900.0;
const MAX_ACTIVE_PER_CHAT: usize = 300;
const MAX_ACTIVE_TOTAL: usize = 20_000;

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Request {
    pub codex_roots: Vec<String>,
    pub claude_roots: Vec<String>,
    pub since: f64,
    pub until: f64,
    pub now: f64,
    #[serde(default)]
    pub previews: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Provider {
    Codex,
    Claude,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Turn,
    Reply,
    Question,
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Session {
    pub provider: &'static str,
    pub id: String,
    pub cwd: Option<String>,
    pub turns: u32,
    pub replies: u32,
    pub questions: u32,
    pub last_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<String>,
    /// When the agent was active within the day, as sorted, non-overlapping `[start, end]` pairs.
    /// Left out (not empty) when the answer's bound was reached, so the app can't read it as idle.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active: Option<Vec<[f64; 2]>>,
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Batch {
    pub turns_by_hour: Vec<u32>,
    pub replies_by_hour: Vec<u32>,
    pub questions: u32,
    pub first_turn: Option<f64>,
    pub last_turn: Option<f64>,
    pub sessions: Vec<Session>,
    pub partial: bool,
    pub reads: usize,
    pub cache_hits: usize,
    pub visited: usize,
}

struct Parsed {
    id: String,
    cwd: Option<Arc<str>>,
    events: Vec<(f64, Kind)>,
    partial: bool,
    /// The chat's title from Claude's `custom-title` (preferred) or `ai-title` lines.
    title: Option<Arc<str>>,
    custom_title: bool,
    /// For tail reads, the earliest timestamp the tail reaches; the file has older lines.
    tail_from: Option<f64>,
    /// Agent activity over the whole file: events less than `ACTIVE_GAP` apart merged, in order.
    active: Vec<(f64, f64)>,
    /// The last turn hadn't finished when the file was read.
    running: bool,
}

struct Entry {
    stamp: Stamp,
    parsed: Arc<Parsed>,
    used: u64,
}

#[derive(Default)]
pub(crate) struct Worker {
    cache: HashMap<PathBuf, Entry>,
    generation: u64,
}

fn timestamp(value: &Value) -> Option<f64> {
    let text = value.as_str().filter(|s| s.len() <= 64)?;
    let time = chrono::DateTime::parse_from_rfc3339(text).ok()?;
    Some(time.timestamp() as f64 + time.timestamp_subsec_nanos() as f64 / 1e9)
}

fn folder(value: &Value) -> Option<&str> {
    value
        .as_str()
        .filter(|s| s.starts_with('/') && s.len() <= MAX_PATH && !s.chars().any(char::is_control))
}

/// A chat id from the file name: Codex rollouts end in the thread UUID, Claude files are the session UUID.
fn session_id(path: &Path, provider: Provider) -> Option<String> {
    let stem = path.file_stem()?.to_str()?;
    let id = match provider {
        Provider::Codex => stem.get(stem.len().checked_sub(36)?..)?,
        Provider::Claude => stem,
    };
    let valid = id.len() == 36
        && id
            .chars()
            .enumerate()
            .all(|(i, c)| if [8, 13, 18, 23].contains(&i) { c == '-' } else { c.is_ascii_hexdigit() });
    valid.then(|| id.to_ascii_lowercase())
}

/// The top-level `"timestamp"` of a line without parsing it; Codex writes it first on every line.
fn quick_timestamp(line: &[u8]) -> Option<f64> {
    const KEY: &[u8] = b"\"timestamp\":\"";
    let start = line.windows(KEY.len()).take(256).position(|w| w == KEY)? + KEY.len();
    let rest = line.get(start..start + 64.min(line.len() - start))?;
    let end = rest.iter().position(|b| *b == b'"')?;
    let text = std::str::from_utf8(&rest[..end]).ok()?;
    timestamp(&Value::String(text.to_owned()))
}

/// Events (time, whether the turn still owed something after it) joined into stretches: a gap of
/// `ACTIVE_GAP` or more starts a new one, unless the turn was still owing something and the gap is
/// at most `MAX_BRIDGE`.
fn merge_active(mut events: Vec<(f64, bool)>) -> Vec<(f64, f64)> {
    events.sort_by(|a, b| a.0.total_cmp(&b.0));
    let mut out: Vec<(f64, f64)> = Vec::new();
    let mut owing = false;
    for (at, owes) in events {
        match out.last_mut() {
            Some(last) if at - last.1 < ACTIVE_GAP || (owing && at - last.1 <= MAX_BRIDGE) => last.1 = last.1.max(at),
            _ => out.push((at, at)),
        }
        owing = owes;
    }
    out
}

/// A Claude user line that only records a local command (a slash command, its output, a `!` shell
/// line) or a compact summary: nothing is owed after it.
fn claude_local(object: &Value) -> bool {
    if object["isCompactSummary"].as_bool() == Some(true) {
        return true;
    }
    let content = &object["message"]["content"];
    let text = content.as_str().or_else(|| content[0]["text"].as_str()).unwrap_or_default().trim_start();
    [
        "<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>", "<local-command-stderr>",
        "<local-command-caveat>", "<bash-input>", "<bash-stdout>", "<bash-stderr>",
    ]
    .iter()
    .any(|tag| text.starts_with(tag))
}

/// The stretches inside `[since, until)`, the last one reaching `now` while its turn runs.
fn active_in_day(parsed: &Parsed, since: f64, until: f64, now: f64) -> Vec<[f64; 2]> {
    let count = parsed.active.len();
    parsed
        .active
        .iter()
        .enumerate()
        .filter_map(|(index, &(start, mut end))| {
            if index + 1 == count && parsed.running && now > end && now - end <= RUNNING_QUIET {
                end = now;
            }
            let (start, end) = (start.max(since), end.min(until));
            (start <= end && start < until && end >= since).then_some([start, end])
        })
        .collect()
}

fn claude_human(object: &Value) -> bool {
    if object["isMeta"].as_bool() == Some(true) || object["isSidechain"].as_bool() == Some(true) {
        return false;
    }
    match &object["message"]["content"] {
        Value::String(text) => !text.trim_start().starts_with('<'),
        Value::Array(items) => {
            items.iter().any(|item| item["type"] == "text")
                && !items.iter().any(|item| item["type"] == "tool_result")
        }
        _ => false,
    }
}

fn parse(bytes: &[u8], provider: Provider, id: String, deadline: Instant) -> Parsed {
    let mut parsed = Parsed {
        id, cwd: None, events: Vec::new(), partial: false, title: None, custom_title: false, tail_from: None,
        active: Vec::new(), running: false,
    };
    let mut seen_replies: HashSet<String> = HashSet::new();
    // Each event's time and whether the turn still owed something after it.
    let mut activity: Vec<(f64, bool)> = Vec::new();
    // The agent is waiting on you (an approval or a question) after the latest line.
    let mut waiting = false;
    for line in bytes.split(|b| *b == b'\n').filter(|line| !line.is_empty()) {
        if Instant::now() >= deadline || parsed.events.len() >= 200_000 || activity.len() >= 400_000 {
            parsed.partial = true;
            break;
        }
        let contains = |needle: &[u8]| line.windows(needle.len()).any(|w| w == needle);
        if provider == Provider::Codex {
            // Every event and response line is agent activity; the envelope's type and a lifecycle
            // kind sit at the start of the line, so only that much is searched.
            let head = &line[..line.len().min(192)];
            let in_head = |needle: &[u8]| head.windows(needle.len()).any(|w| w == needle);
            if in_head(b"\"event_msg\"") || in_head(b"\"response_item\"") {
                waiting = false;
                if in_head(b"\"event_msg\"")
                    && [&b"_started\""[..], b"_complete\"", b"_aborted\"", b"_required\"", b"request_user_input\""]
                        .iter()
                        .any(|kind| in_head(kind))
                {
                    if let Ok(object) = serde_json::from_slice::<Value>(line) {
                        match object["payload"]["type"].as_str().and_then(crate::status_policy::codex_event) {
                            // Waiting on you: the turn stays open, but the gap after it isn't work.
                            Some((crate::EventState::Waiting, _)) => waiting = true,
                            Some((state, _)) => parsed.running = state == crate::EventState::Working,
                            None => {}
                        }
                    }
                } else if in_head(b"\"response_item\"") && contains(b"request_user_input") {
                    if let Ok(object) = serde_json::from_slice::<Value>(line) {
                        waiting = object["payload"]["name"].as_str().is_some_and(|name| name.starts_with("request_user_input"));
                    }
                }
                if let Some(at) = quick_timestamp(line) {
                    activity.push((at, parsed.running && !waiting));
                }
            }
        }
        let relevant = match provider {
            Provider::Codex => {
                contains(b"task_started")
                    || contains(b"\"assistant\"")
                    || contains(b"request_user_input")
                    || contains(b"turn_context")
            }
            Provider::Claude => {
                contains(b"\"type\":\"user\"")
                    || contains(b"\"type\":\"assistant\"")
                    || contains(b"custom-title")
                    || contains(b"ai-title")
            }
        };
        if !relevant {
            continue;
        }
        if line.len() > 4 * 1024 * 1024 {
            parsed.partial = true;
            continue;
        }
        let Ok(object) = serde_json::from_slice::<Value>(line) else {
            parsed.partial = true;
            continue;
        };
        let at = timestamp(&object["timestamp"]);
        match provider {
            Provider::Codex => {
                let payload = &object["payload"];
                if object["type"] == "turn_context" {
                    if let Some(path) = folder(&payload["cwd"]) {
                        if parsed.cwd.as_deref() != Some(path) {
                            parsed.cwd = Some(Arc::from(path));
                        }
                    }
                    continue;
                }
                let Some(at) = at else { continue };
                if object["type"] == "event_msg" && payload["type"] == "task_started" {
                    parsed.events.push((at, Kind::Turn));
                } else if object["type"] == "response_item" && payload["type"] == "message" && payload["role"] == "assistant" {
                    parsed.events.push((at, Kind::Reply));
                } else if object["type"] == "response_item"
                    && payload["name"].as_str().is_some_and(|name| name.starts_with("request_user_input"))
                {
                    parsed.events.push((at, Kind::Question));
                }
            }
            Provider::Claude => {
                if matches!(object["type"].as_str(), Some("user" | "assistant")) && object["isMeta"].as_bool() != Some(true) {
                    // The main chain owes something after your message, a tool result or a tool call;
                    // nothing after a local command or a compact summary; a thinking-only line changes nothing.
                    if object["isSidechain"].as_bool() != Some(true) {
                        let content = &object["message"]["content"];
                        if object["type"] == "user" {
                            waiting = false;
                            parsed.running = !claude_local(&object)
                                && !content.as_str().or_else(|| content[0]["text"].as_str())
                                    .is_some_and(|text| text.starts_with("[Request interrupted"));
                        } else {
                            let items = content.as_array().map(Vec::as_slice).unwrap_or_default();
                            let thinking = !items.is_empty()
                                && items.iter().all(|item| matches!(item["type"].as_str(), Some("thinking" | "redacted_thinking")));
                            if !thinking {
                                parsed.running = items.iter().any(|item| item["type"] == "tool_use");
                                // A question or a plan to approve: the gap after it is yours, not the agent's.
                                waiting = items.iter().any(|item| {
                                    item["type"] == "tool_use" && matches!(item["name"].as_str(), Some("AskUserQuestion" | "ExitPlanMode"))
                                });
                            }
                        }
                    }
                    if let Some(at) = at {
                        activity.push((at, parsed.running && !waiting));
                    }
                }
                let title = match object["type"].as_str() {
                    Some("custom-title") => Some((object["customTitle"].as_str(), true)),
                    Some("ai-title") if !parsed.custom_title => Some((object["aiTitle"].as_str(), false)),
                    _ => None,
                };
                if let Some((Some(text), custom)) = title {
                    let clean: String = text.chars().filter(|c| !c.is_control()).take(120).collect();
                    if !clean.trim().is_empty() {
                        parsed.title = Some(Arc::from(clean.trim()));
                        parsed.custom_title |= custom;
                    }
                    continue;
                }
                if let Some(path) = folder(&object["cwd"]) {
                    if parsed.cwd.as_deref() != Some(path) {
                        parsed.cwd = Some(Arc::from(path));
                    }
                }
                let Some(at) = at else { continue };
                if object["type"] == "user" {
                    if claude_human(&object) {
                        parsed.events.push((at, Kind::Turn));
                    }
                } else if object["type"] == "assistant" && object["isSidechain"].as_bool() != Some(true) {
                    let content = object["message"]["content"].as_array().cloned().unwrap_or_default();
                    if content
                        .iter()
                        .any(|item| item["type"] == "tool_use" && item["name"] == "AskUserQuestion")
                    {
                        parsed.events.push((at, Kind::Question));
                    }
                    // Streaming splits one reply into several lines that share a message id.
                    let message = object["message"]["id"].as_str().unwrap_or_default();
                    if content.iter().any(|item| item["type"] == "text")
                        && message.len() <= 256
                        && seen_replies.insert(message.to_owned())
                    {
                        parsed.events.push((at, Kind::Reply));
                    }
                }
            }
        }
    }
    parsed.active = merge_active(activity);
    // Waiting on you isn't agent work, so it doesn't reach now either.
    parsed.running &= !waiting;
    parsed
}

/// The first line of the newest reply in a file's tail, trimmed to a short preview.
fn preview(path: &Path, provider: Provider) -> Option<String> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let length = file.metadata().ok()?.len();
    let start = length.saturating_sub(PREVIEW_TAIL);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut bytes = Vec::new();
    file.take(PREVIEW_TAIL).read_to_end(&mut bytes).ok()?;
    for line in bytes.split(|b| *b == b'\n').rev() {
        if line.is_empty() || !line.windows(11).any(|w| w == b"\"assistant\"") {
            continue;
        }
        let Ok(object) = serde_json::from_slice::<Value>(line) else { continue };
        let items = match provider {
            Provider::Codex if object["payload"]["role"] == "assistant" => object["payload"]["content"].clone(),
            Provider::Claude if object["type"] == "assistant" && object["isSidechain"].as_bool() != Some(true) => {
                object["message"]["content"].clone()
            }
            _ => continue,
        };
        let text = items.as_array()?.iter().rev().find_map(|item| {
            let kind = item["type"].as_str()?;
            (kind == "text" || kind == "output_text").then(|| item["text"].as_str()).flatten()
        });
        if let Some(text) = text {
            let line = text
                .lines()
                .map(|l| l.trim().trim_start_matches(['#', '*', '-', '>', ' ']))
                .find(|l| !l.is_empty())?;
            let clean: String = line
                .replace("**", "")
                .replace("__", "")
                .replace('`', "")
                .chars()
                .filter(|c| !c.is_control())
                .take(PREVIEW_CHARS)
                .collect();
            return (!clean.is_empty()).then_some(clean);
        }
    }
    None
}

impl Worker {
    fn file(&mut self, path: &Path, provider: Provider, id: String, deadline: Instant, batch: &mut Batch) -> io::Result<Arc<Parsed>> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(path)?;
        let before = file.metadata()?;
        if !before.is_file() || before.uid() != unsafe { libc::geteuid() } {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let stamp = Stamp::from(&before);
        if let Some(entry) = self.cache.get_mut(path).filter(|entry| entry.stamp == stamp) {
            entry.used = self.generation;
            batch.cache_hits += 1;
            return Ok(entry.parsed.clone());
        }
        let tail = before.len() > MAX_FILE;
        let offset = if tail { before.len() - MAX_TAIL } else { 0 };
        let mut reader = &file;
        reader.seek(SeekFrom::Start(offset))?;
        let mut bytes = Vec::with_capacity((before.len() - offset) as usize);
        reader.take(MAX_TAIL.max(MAX_FILE) + 1).read_to_end(&mut bytes)?;
        batch.reads += 1;
        if bytes.len() as u64 != before.len() - offset || Stamp::from(&file.metadata()?) != stamp {
            return Err(io::ErrorKind::Interrupted.into());
        }
        if tail {
            // Drop the partial first line of the window.
            let start = bytes.iter().position(|b| *b == b'\n').map_or(bytes.len(), |i| i + 1);
            bytes.drain(..start);
        }
        let mut parsed = parse(&bytes, provider, id, deadline);
        if tail {
            parsed.tail_from = Some(parsed.events.first().map_or(f64::INFINITY, |e| e.0));
        }
        let parsed = Arc::new(parsed);
        if Instant::now() < deadline && !parsed.partial {
            self.cache.insert(path.to_owned(), Entry { stamp, parsed: parsed.clone(), used: self.generation });
            if self.cache.len() > 4096 {
                let mut oldest: Vec<_> = self.cache.iter().map(|(k, e)| (k.clone(), e.used)).collect();
                oldest.sort_by_key(|(_, used)| *used);
                for (key, _) in oldest.into_iter().take(1024) {
                    self.cache.remove(&key);
                }
            }
        }
        Ok(parsed)
    }

    pub(crate) fn scan(&mut self, request: Request) -> io::Result<Batch> {
        let roots = request.codex_roots.iter().map(|r| (r, Provider::Codex))
            .chain(request.claude_roots.iter().map(|r| (r, Provider::Claude)));
        let roots: Vec<_> = roots.collect();
        let span = request.until - request.since;
        if roots.is_empty()
            || request.codex_roots.len() > 3
            || request.claude_roots.len() > 3
            || roots.iter().any(|(r, _)| !Path::new(r).is_absolute() || r.len() > MAX_PATH)
            || ![request.since, request.until, request.now].iter().all(|v| v.is_finite() && (0.0..=253402300799.0).contains(v))
            || !(3600.0 * 20.0..=3600.0 * 26.0).contains(&span)
            || request.since > request.now + 60.0
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        self.generation += 1;
        let deadline = Instant::now() + Duration::from_secs(15);
        let hours = (span / 3600.0).ceil() as usize;
        let mut batch = Batch { turns_by_hour: vec![0; hours], replies_by_hour: vec![0; hours], ..Batch::default() };
        let mut files: Vec<(PathBuf, Provider, f64)> = Vec::new();
        // Entries carry the type their directory reported; only the roots and logs are stat'ed.
        let mut stack: Vec<(PathBuf, Provider, Option<fs::FileType>)> =
            roots.iter().map(|(r, p)| (PathBuf::from(r), *p, None)).collect();
        while let Some((path, provider, known)) = stack.pop() {
            if batch.visited >= MAX_VISITED || Instant::now() >= deadline {
                batch.partial = true;
                break;
            }
            batch.visited += 1;
            let mut meta = None;
            let kind = match known {
                Some(kind) => kind,
                None => {
                    let Ok(m) = fs::symlink_metadata(&path) else { continue };
                    let kind = m.file_type();
                    meta = Some(m);
                    kind
                }
            };
            if kind.is_symlink() {
                continue;
            }
            if kind.is_dir() {
                // Claude worker transcripts live in <session>/subagents; their turns aren't yours.
                if path.file_name().is_some_and(|n| n == "subagents") {
                    continue;
                }
                match fs::read_dir(&path) {
                    Ok(entries) => {
                        for entry in entries.flatten() {
                            if stack.len() + batch.visited >= MAX_VISITED {
                                batch.partial = true;
                                break;
                            }
                            stack.push((entry.path(), provider, entry.file_type().ok()));
                        }
                    }
                    Err(_) => batch.partial = true,
                }
                continue;
            }
            if path.extension().is_none_or(|e| e != "jsonl") {
                continue;
            }
            let meta = match meta {
                Some(meta) => meta,
                None => {
                    let Ok(meta) = fs::symlink_metadata(&path) else { continue };
                    meta
                }
            };
            let modified = meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9;
            if meta.is_file() && modified >= request.since {
                files.push((path, provider, modified));
            }
        }
        files.sort_by(|a, b| b.2.total_cmp(&a.2).then_with(|| a.0.cmp(&b.0)));
        let mut budget = 0;
        let mut active_total = 0;
        let mut sessions: Vec<(PathBuf, Provider, Session)> = Vec::new();
        for (path, provider, _) in files {
            if budget >= MAX_BYTES || Instant::now() >= deadline {
                batch.partial = true;
                break;
            }
            let Some(id) = session_id(&path, provider) else { continue };
            budget += fs::metadata(&path).map(|m| m.len().min(MAX_TAIL)).unwrap_or(0);
            let parsed = match self.file(&path, provider, id, deadline, &mut batch) {
                Ok(parsed) => parsed,
                Err(_) => {
                    batch.partial = true;
                    continue;
                }
            };
            batch.partial |= parsed.partial || parsed.tail_from.is_some_and(|from| from > request.since);
            let mut session = Session {
                provider: if provider == Provider::Codex { "codex" } else { "claude" },
                id: parsed.id.clone(),
                cwd: parsed.cwd.as_deref().map(str::to_owned),
                title: parsed.title.as_deref().map(str::to_owned),
                ..Session::default()
            };
            for &(at, kind) in parsed.events.iter().filter(|(at, _)| *at >= request.since && *at < request.until) {
                let hour = (((at - request.since) / 3600.0) as usize).min(hours - 1);
                match kind {
                    Kind::Turn => {
                        session.turns += 1;
                        batch.turns_by_hour[hour] += 1;
                        batch.first_turn = Some(batch.first_turn.map_or(at, |f: f64| f.min(at)));
                        batch.last_turn = Some(batch.last_turn.map_or(at, |l: f64| l.max(at)));
                    }
                    Kind::Reply => {
                        session.replies += 1;
                        batch.replies_by_hour[hour] += 1;
                    }
                    Kind::Question => {
                        session.questions += 1;
                        batch.questions += 1;
                    }
                }
                session.last_at = session.last_at.max(at);
            }
            let active = active_in_day(&parsed, request.since, request.until, request.now);
            if session.last_at == 0.0 {
                // Only tool work today (the turn began earlier): dated by its last stretch, inside the day.
                session.last_at = active.last().map_or(0.0, |pair| pair[1].min(request.until - 0.001));
            }
            if active.len() > MAX_ACTIVE_PER_CHAT || active_total + active.len() > MAX_ACTIVE_TOTAL {
                batch.partial = true;
            } else if session.turns + session.replies + session.questions > 0 || !active.is_empty() {
                active_total += active.len();
                session.active = Some(active);
            }
            if session.turns + session.replies + session.questions > 0 || session.active.as_ref().is_some_and(|a| !a.is_empty()) {
                if sessions.len() >= MAX_SESSIONS {
                    batch.partial = true;
                } else {
                    sessions.push((path, provider, session));
                }
            }
        }
        sessions.sort_by(|a, b| b.2.last_at.total_cmp(&a.2.last_at));
        if request.previews {
            for (path, provider, session) in sessions.iter_mut().take(MAX_PREVIEWS) {
                if Instant::now() >= deadline {
                    batch.partial = true;
                    break;
                }
                session.preview = preview(path, *provider);
            }
        }
        batch.sessions = sessions.into_iter().map(|(_, _, s)| s).collect();
        Ok(batch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn lines(values: &[Value]) -> Vec<u8> {
        values.iter().map(|v| v.to_string()).collect::<Vec<_>>().join("\n").into_bytes()
    }
    const ID: &str = "01a1be01-5798-7cc1-9a11-57d9fc33c0da";

    #[test]
    fn codex_counts_turns_replies_and_questions() {
        let bytes = lines(&[
            serde_json::json!({"type":"turn_context","payload":{"cwd":"/work/app"}}),
            serde_json::json!({"type":"event_msg","timestamp":"2026-11-09T01:00:00Z","payload":{"type":"task_started"}}),
            serde_json::json!({"type":"response_item","timestamp":"2026-11-09T01:00:05Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}),
            serde_json::json!({"type":"response_item","timestamp":"2026-11-09T01:00:06Z","payload":{"type":"function_call","name":"request_user_input_async"}}),
            serde_json::json!({"type":"response_item","timestamp":"2026-11-09T01:00:07Z","payload":{"type":"message","role":"user","content":[]}}),
        ]);
        let parsed = parse(&bytes, Provider::Codex, ID.into(), Instant::now() + Duration::from_secs(1));
        let kinds: Vec<_> = parsed.events.iter().map(|e| e.1).collect();
        assert_eq!(kinds, [Kind::Turn, Kind::Reply, Kind::Question]);
        assert_eq!(parsed.cwd.as_deref(), Some("/work/app"));
    }

    #[test]
    fn claude_counts_human_turns_once_per_reply_and_skips_tools_meta_and_sidechains() {
        let bytes = lines(&[
            serde_json::json!({"type":"user","cwd":"/work/b","timestamp":"2026-11-09T02:00:00Z","message":{"content":"Fix the build"}}),
            serde_json::json!({"type":"user","timestamp":"2026-11-09T02:00:01Z","isMeta":true,"message":{"content":"Caveat"}}),
            serde_json::json!({"type":"user","timestamp":"2026-11-09T02:00:02Z","message":{"content":[{"type":"tool_result","content":"ok"}]}}),
            serde_json::json!({"type":"user","timestamp":"2026-11-09T02:00:02Z","message":{"content":"<command-name>/clear</command-name>"}}),
            serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:03Z","message":{"id":"m1","content":[{"type":"text","text":"On it"}]}}),
            serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:04Z","message":{"id":"m1","content":[{"type":"tool_use","name":"AskUserQuestion"}]}}),
            serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:05Z","isSidechain":true,"message":{"id":"m2","content":[{"type":"text","text":"worker"}]}}),
            serde_json::json!({"type":"custom-title","customTitle":"Fix the build"}),
            serde_json::json!({"type":"ai-title","aiTitle":"Ignored after a custom title"}),
        ]);
        let parsed = parse(&bytes, Provider::Claude, ID.into(), Instant::now() + Duration::from_secs(1));
        let kinds: Vec<_> = parsed.events.iter().map(|e| e.1).collect();
        assert_eq!(kinds, [Kind::Turn, Kind::Reply, Kind::Question]);
        assert_eq!(parsed.cwd.as_deref(), Some("/work/b"));
        assert_eq!(parsed.title.as_deref(), Some("Fix the build"), "a custom title beats a later AI title");
    }

    #[test]
    fn oversized_files_are_read_from_the_tail() {
        let folder = crate::tests::Fixture::new();
        let since = 1_794_150_000.0;
        let at = |offset: f64| chrono::DateTime::from_timestamp((since + offset) as i64, 0).unwrap().to_rfc3339();
        let dir = folder.0.join("claude/proj");
        fs::create_dir_all(&dir).unwrap();
        let mut bytes = Vec::new();
        let old = serde_json::json!({"type":"user","timestamp":at(-7200.0),"message":{"content":"old"},"pad":"x".repeat(1024)}).to_string();
        while (bytes.len() as u64) < MAX_FILE + 1024 { bytes.extend_from_slice(old.as_bytes()); bytes.push(b'\n'); }
        bytes.extend_from_slice(serde_json::json!({"type":"user","timestamp":at(3600.0),"message":{"content":"today"}}).to_string().as_bytes());
        fs::write(dir.join(format!("{ID}.jsonl")), bytes).unwrap();
        let batch = Worker::default()
            .scan(Request { codex_roots: vec![], claude_roots: vec![folder.0.join("claude").to_string_lossy().into()],
                            since, until: since + 86400.0, now: since + 86400.0, previews: false })
            .unwrap();
        assert_eq!(batch.turns_by_hour[1], 1, "today's turn at the end is counted");
        assert!(!batch.partial, "the tail reaches back before the day, so nothing is missing");
    }

    fn parsed(active: Vec<(f64, f64)>, running: bool) -> Parsed {
        Parsed { id: ID.into(), cwd: None, events: vec![], partial: false, title: None, custom_title: false, tail_from: None, active, running }
    }

    #[test]
    fn events_under_five_minutes_apart_merge_into_one_stretch() {
        let quiet = |times: &[f64]| times.iter().map(|&t| (t, false)).collect::<Vec<_>>();
        assert_eq!(merge_active(quiet(&[700.0, 0.0, 100.0, 399.0, 999.0, 1299.0, 1700.0])), [(0.0, 399.0), (700.0, 999.0), (1299.0, 1299.0), (1700.0, 1700.0)],
                   "299 s apart joins, exactly 300 s apart starts a new stretch, a lone event is a zero-length one");
        assert!(merge_active(vec![]).is_empty());
    }

    #[test]
    fn a_gap_while_the_turn_owes_something_joins_up_to_the_cap() {
        // Owing after 0 (a tool call): the result at 20 minutes joins; after it nothing is owed.
        assert_eq!(merge_active(vec![(1200.0, false), (0.0, true), (1500.0, false)]), [(0.0, 1200.0), (1500.0, 1500.0)]);
        assert_eq!(merge_active(vec![(0.0, true), (MAX_BRIDGE, false)]), [(0.0, MAX_BRIDGE)], "exactly the cap still joins");
        assert_eq!(merge_active(vec![(0.0, true), (MAX_BRIDGE + 1.0, false)]), [(0.0, 0.0), (MAX_BRIDGE + 1.0, MAX_BRIDGE + 1.0)],
                   "past the cap it's a stall");
    }

    #[test]
    fn stretches_are_clipped_to_the_day() {
        let day = parsed(vec![(-600.0, 120.0), (500.0, 900.0), (86_000.0, 87_000.0), (90_000.0, 91_000.0), (-900.0, -800.0)], false);
        // (-900, -800) sorts first in real files; here order doesn't matter for clipping.
        assert_eq!(active_in_day(&day, 0.0, 86_400.0, 100_000.0), [[0.0, 120.0], [500.0, 900.0], [86_000.0, 86_400.0]]);
    }

    #[test]
    fn a_running_turn_reaches_now_unless_the_file_went_quiet() {
        let running = parsed(vec![(100.0, 200.0), (1000.0, 1600.0)], true);
        assert_eq!(active_in_day(&running, 0.0, 86_400.0, 2000.0), [[100.0, 200.0], [1000.0, 2000.0]], "only the last stretch extends");
        assert_eq!(active_in_day(&running, 0.0, 86_400.0, 1600.0 + RUNNING_QUIET + 1.0).last(), Some(&[1000.0, 1600.0]), "quiet too long");
        assert_eq!(active_in_day(&parsed(vec![(1000.0, 1600.0)], false), 0.0, 86_400.0, 2000.0), [[1000.0, 1600.0]]);
        // Viewing yesterday while the turn still runs: it reaches the end of that day.
        assert_eq!(active_in_day(&running, 0.0, 1800.0, 2000.0).last(), Some(&[1000.0, 1800.0]));
    }

    #[test]
    fn codex_running_follows_the_last_lifecycle_event_and_counts_tool_lines() {
        let started = serde_json::json!({"timestamp":"2026-11-09T01:00:00Z","type":"event_msg","payload":{"type":"task_started"}});
        let tool = serde_json::json!({"timestamp":"2026-11-09T01:04:00Z","type":"response_item","payload":{"type":"function_call","name":"shell"}});
        let output = serde_json::json!({"timestamp":"2026-11-09T01:08:30Z","type":"response_item","payload":{"type":"function_call_output"}});
        let done = serde_json::json!({"timestamp":"2026-11-09T01:20:00Z","type":"event_msg","payload":{"type":"task_complete"}});
        let deadline = Instant::now() + Duration::from_secs(1);
        let open = parse(&lines(&[started.clone(), tool.clone(), output.clone()]), Provider::Codex, ID.into(), deadline);
        assert!(open.running);
        let t0 = 1_794_186_000.0; // 2026-11-09T01:00:00Z
        assert_eq!(open.active, [(t0, t0 + 510.0)], "tool calls and their output keep the stretch going");
        let closed = parse(&lines(&[started.clone(), tool, output, done.clone()]), Provider::Codex, ID.into(), deadline);
        assert!(!closed.running);
        assert_eq!(closed.active, [(t0, t0 + 1200.0)], "11.5 quiet minutes inside a running task don't split the stretch");
        // After the task completed, a quiet gap splits again.
        let next = serde_json::json!({"timestamp":"2026-11-09T01:40:00Z","type":"event_msg","payload":{"type":"task_started"}});
        let after = parse(&lines(&[started.clone(), done.clone(), next]), Provider::Codex, ID.into(), deadline);
        assert_eq!(after.active, [(t0, t0 + 1200.0), (t0 + 2400.0, t0 + 2400.0)]);
        // A task quiet for longer than the cap splits (it may have been waiting on you).
        let late = serde_json::json!({"timestamp":"2026-11-09T04:30:00Z","type":"event_msg","payload":{"type":"task_complete"}});
        let stalled = parse(&lines(&[started, late]), Provider::Codex, ID.into(), deadline);
        assert_eq!(stalled.active, [(t0, t0), (t0 + 12_600.0, t0 + 12_600.0)]);
    }

    #[test]
    fn claude_long_tool_calls_stay_one_stretch_and_quiet_gaps_after_a_reply_split() {
        let deadline = Instant::now() + Duration::from_secs(1);
        let t0 = 1_794_189_600.0; // 2026-11-09T02:00:00Z
        let ask = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:00:00Z","message":{"content":"Run the suite"}});
        let tool = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:10Z","message":{"id":"a","content":[{"type":"tool_use","name":"Bash"}]}});
        let result = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:20:00Z","message":{"content":[{"type":"tool_result","content":"ok"}]}});
        let reply = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:21:00Z","message":{"id":"b","content":[{"type":"text","text":"Green"}]}});
        let again = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:41:00Z","message":{"content":"Ship it"}});
        let late = serde_json::json!({"type":"user","timestamp":"2026-11-09T04:00:10Z","message":{"content":[{"type":"tool_result","content":"ok"}]}});
        let run = |values: &[Value]| parse(&lines(values), Provider::Claude, ID.into(), deadline);
        assert_eq!(run(&[ask.clone(), tool.clone(), result, reply.clone(), again]).active, [(t0, t0 + 1260.0), (t0 + 2460.0, t0 + 2460.0)],
                   "the 20-minute tool call joins; the 20 quiet minutes after the reply split");
        // A thinking-only line while the reply is owed keeps it owed: a long generation joins too.
        let thinking = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:01:00Z","message":{"id":"c","content":[{"type":"thinking","thinking":"…"}]}});
        let answer = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:15:00Z","message":{"id":"c","content":[{"type":"text","text":"Here"}]}});
        assert_eq!(run(&[ask.clone(), thinking, answer]).active, [(t0, t0 + 900.0)]);
        assert_eq!(run(&[ask, tool, late]).active, [(t0, t0 + 10.0), (t0 + 7210.0, t0 + 7210.0)],
                   "a 2-hour gap after a tool call isn't bridged: it may have waited for your approval");
    }

    #[test]
    fn waits_on_you_are_never_bridged() {
        let deadline = Instant::now() + Duration::from_secs(1);
        let t0 = 1_794_186_000.0; // 2026-11-09T01:00:00Z
        // Codex: an approval request, approved 10 minutes later.
        let started = serde_json::json!({"timestamp":"2026-11-09T01:00:00Z","type":"event_msg","payload":{"type":"task_started"}});
        let call = serde_json::json!({"timestamp":"2026-11-09T01:00:20Z","type":"response_item","payload":{"type":"function_call","name":"shell"}});
        let approval = serde_json::json!({"timestamp":"2026-11-09T01:00:30Z","type":"event_msg","payload":{"type":"approval_required"}});
        let output = serde_json::json!({"timestamp":"2026-11-09T01:10:30Z","type":"response_item","payload":{"type":"function_call_output"}});
        let codex = |values: &[Value]| parse(&lines(values), Provider::Codex, ID.into(), deadline);
        let waited = codex(&[started.clone(), call.clone(), approval.clone(), output.clone()]);
        assert_eq!(waited.active, [(t0, t0 + 30.0), (t0 + 630.0, t0 + 630.0)], "the approval wait splits even under the cap");
        assert!(waited.running, "after the approval the task runs again");
        assert!(!codex(&[started.clone(), call.clone(), approval]).running, "waiting on you isn't running");
        assert_eq!(codex(&[started.clone(), call.clone(), output.clone()]).active, [(t0, t0 + 630.0)], "the same gap without a wait joins");
        let ask = serde_json::json!({"timestamp":"2026-11-09T01:00:30Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input"}});
        assert_eq!(codex(&[started, call, ask, output]).active.len(), 2, "a question to you splits too");
        // Claude: a question to you, answered 10 minutes later.
        let t1 = t0 + 3600.0;
        let you = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:00:00Z","message":{"content":"Plan it"}});
        let question = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:10Z","message":{"id":"a","content":[{"type":"tool_use","name":"AskUserQuestion"}]}});
        let answer = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:10:10Z","message":{"content":[{"type":"tool_result","content":"B"}]}});
        let claude = |values: &[Value]| parse(&lines(values), Provider::Claude, ID.into(), deadline);
        assert!(!claude(&[you.clone(), question.clone()]).running, "a question waiting on you isn't running");
        assert_eq!(claude(&[you.clone(), question, answer.clone()]).active, [(t1, t1 + 10.0), (t1 + 610.0, t1 + 610.0)]);
        let plan = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:10Z","message":{"id":"a","content":[{"type":"tool_use","name":"ExitPlanMode"}]}});
        assert_eq!(claude(&[you, plan, answer]).active.len(), 2, "a plan waiting for approval splits too");
    }

    #[test]
    fn claude_local_commands_and_compact_summaries_owe_nothing_and_thinking_changes_nothing() {
        let deadline = Instant::now() + Duration::from_secs(1);
        let run = |values: &[Value]| parse(&lines(values), Provider::Claude, ID.into(), deadline);
        let reply = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:00Z","message":{"id":"a","content":[{"type":"text","text":"Done"}]}});
        let tool = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:00Z","message":{"id":"a","content":[{"type":"tool_use","name":"Bash"}]}});
        let thinking = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:05Z","message":{"id":"b","content":[{"type":"thinking","thinking":"…"}]}});
        for text in ["<command-name>/model</command-name>", "<local-command-stdout>Set model</local-command-stdout>",
                     "<command-message>clear</command-message>", "<bash-input>ls</bash-input>", "<bash-stdout>a</bash-stdout>"] {
            let local = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:01:00Z","message":{"content":text}});
            assert!(!run(&[reply.clone(), local.clone()]).running, "{text}");
            let array = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:01:00Z","message":{"content":[{"type":"text","text":text}]}});
            assert!(!run(&[reply.clone(), array]).running, "{text} as a text item");
        }
        let summary = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:01:00Z","isCompactSummary":true,
                                         "message":{"content":"This session is being continued from a previous conversation"}});
        assert!(!run(&[reply.clone(), summary]).running, "a compact summary isn't a turn");
        assert!(run(&[tool, thinking.clone()]).running, "thinking after a tool call leaves it owed");
        assert!(!run(&[reply, thinking]).running, "thinking after a reply doesn't reopen the turn");
    }

    #[test]
    fn claude_running_means_the_main_chain_owes_a_reply() {
        let deadline = Instant::now() + Duration::from_secs(1);
        let ask = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:00:00Z","message":{"content":"Fix it"}});
        let tool = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:00:10Z","message":{"id":"a","content":[{"type":"tool_use","name":"Bash"}]}});
        let result = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:03:00Z","message":{"content":[{"type":"tool_result","content":"ok"}]}});
        let reply = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:04:00Z","message":{"id":"b","content":[{"type":"text","text":"Done"}]}});
        let side = serde_json::json!({"type":"assistant","timestamp":"2026-11-09T02:05:00Z","isSidechain":true,"message":{"id":"c","content":[{"type":"tool_use","name":"Read"}]}});
        let stop = serde_json::json!({"type":"user","timestamp":"2026-11-09T02:06:00Z","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}});
        let run = |values: &[Value]| parse(&lines(values), Provider::Claude, ID.into(), deadline);
        assert!(run(&[ask.clone()]).running);
        assert!(run(&[ask.clone(), tool.clone()]).running);
        assert!(run(&[ask.clone(), tool.clone(), result.clone()]).running);
        let finished = run(&[ask.clone(), tool.clone(), result.clone(), reply.clone(), side.clone()]);
        assert!(!finished.running, "a sidechain line after the reply doesn't reopen the turn");
        assert_eq!(finished.active.len(), 1);
        assert_eq!(finished.active[0].1 - finished.active[0].0, 300.0);
        assert!(!run(&[ask, tool, stop]).running, "an interrupted turn isn't running");
    }

    #[test]
    fn scans_return_bounded_active_stretches_and_tool_only_days() {
        let folder = crate::tests::Fixture::new();
        let dir = folder.0.join("codex/2026/11/09");
        fs::create_dir_all(&dir).unwrap();
        let since = 1_794_150_000.0;
        let at = |offset: f64| chrono::DateTime::from_timestamp((since + offset) as i64, 0).unwrap().to_rfc3339();
        // 70 chats, each with 288 stretches (an event every 5 minutes all day): 20,160 stretches in all.
        for chat in 0..70 {
            let events: Vec<Value> = (0..288)
                .map(|i| serde_json::json!({"timestamp": at(i as f64 * 300.0), "type":"response_item","payload":{"type":"function_call"}}))
                .collect();
            fs::write(dir.join(format!("rollout-x-{:08x}-5798-7cc1-9a11-57d9fc33c0da.jsonl", chat)), lines(&events)).unwrap();
        }
        let batch = Worker::default()
            .scan(Request { codex_roots: vec![folder.0.join("codex").to_string_lossy().into()], claude_roots: vec![],
                            since, until: since + 86_400.0, now: since + 86_400.0, previews: false })
            .unwrap();
        let known: Vec<_> = batch.sessions.iter().filter_map(|s| s.active.as_ref()).collect();
        assert!(batch.partial, "past the bound the answer says so");
        assert_eq!(known.iter().map(|a| a.len()).sum::<usize>(), 69 * 288);
        assert!(known.iter().all(|a| a.windows(2).all(|w| w[0][1] < w[1][0]) && a.iter().all(|p| p[0] >= since && p[1] < since + 86_400.0)));
        assert!(batch.sessions.iter().all(|s| s.turns == 0 && s.last_at >= since && s.last_at < since + 86_400.0),
                "chats with only tool work today are listed and dated inside the day");
    }

    #[test]
    fn session_ids_come_from_file_names() {
        assert_eq!(
            session_id(Path::new(&format!("/s/rollout-2026-11-09T10-52-01-{ID}.jsonl")), Provider::Codex).as_deref(),
            Some(ID)
        );
        assert_eq!(session_id(Path::new(&format!("/p/x/{ID}.jsonl")), Provider::Claude).as_deref(), Some(ID));
        assert!(session_id(Path::new("/p/x/agent-123.jsonl"), Provider::Claude).is_none());
    }

    #[test]
    fn scans_a_day_buckets_by_hour_and_previews_without_caching_text() {
        let folder = crate::tests::Fixture::new();
        let claude = folder.0.join("claude/proj");
        fs::create_dir_all(claude.join(format!("{ID}/subagents"))).unwrap();
        let since = 1_794_150_000.0; // 2026-11-08T15:00:00Z
        let at = |offset: f64| chrono::DateTime::from_timestamp((since + offset) as i64, 0).unwrap().to_rfc3339();
        fs::write(
            claude.join(format!("{ID}.jsonl")),
            lines(&[
                serde_json::json!({"type":"user","cwd":"/work/b","timestamp":at(3600.0 * 2.5),"message":{"content":"one"}}),
                serde_json::json!({"type":"assistant","timestamp":at(3600.0 * 2.6),"message":{"id":"a","content":[{"type":"text","text":"## **First** `line`\nsecond"}]}}),
                serde_json::json!({"type":"user","timestamp":at(3600.0 * 9.0),"message":{"content":"two"}}),
                serde_json::json!({"type":"user","timestamp":at(-60.0),"message":{"content":"yesterday"}}),
            ]),
        )
        .unwrap();
        fs::write(claude.join(format!("{ID}/subagents/agent-1.jsonl")), "{\"type\":\"user\"}").unwrap();
        let request = |previews| Request {
            codex_roots: vec![],
            claude_roots: vec![folder.0.join("claude").to_string_lossy().into()],
            since,
            until: since + 86400.0,
            now: since + 86400.0,
            previews,
        };
        let mut worker = Worker::default();
        let batch = worker.scan(request(true)).unwrap();
        assert_eq!(batch.turns_by_hour.len(), 24);
        assert_eq!((batch.turns_by_hour[2], batch.turns_by_hour[9], batch.replies_by_hour[2]), (1, 1, 1));
        assert_eq!(batch.first_turn, Some(since + 3600.0 * 2.5));
        assert_eq!(batch.sessions.len(), 1);
        assert_eq!(batch.sessions[0].turns, 2);
        assert_eq!(batch.sessions[0].preview.as_deref(), Some("First line"));
        let warm = worker.scan(request(false)).unwrap();
        assert_eq!((warm.cache_hits, warm.reads), (1, 0));
        assert!(warm.sessions[0].preview.is_none(), "previews only when asked");
        assert!(worker.scan(Request { until: since + 3600.0, ..request(false) }).is_err());
    }
}
