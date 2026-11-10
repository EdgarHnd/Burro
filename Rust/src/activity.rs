//! One day of agent activity for Burro's Today page: your turns and the agents' replies per
//! hour, explicit questions agents asked you, and per-chat counts. The cache keeps only
//! timestamps, kinds and folders per file, never conversation text. Optional last-reply
//! previews are read fresh from each file's tail and returned, not cached.
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
    let mut parsed = Parsed { id, cwd: None, events: Vec::new(), partial: false, title: None, custom_title: false, tail_from: None };
    let mut seen_replies: HashSet<String> = HashSet::new();
    for line in bytes.split(|b| *b == b'\n').filter(|line| !line.is_empty()) {
        if Instant::now() >= deadline || parsed.events.len() >= 200_000 {
            parsed.partial = true;
            break;
        }
        let contains = |needle: &[u8]| line.windows(needle.len()).any(|w| w == needle);
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
            if session.turns + session.replies + session.questions > 0 {
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
