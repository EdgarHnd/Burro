//! Bounded Claude worker discovery and lifecycle reduction. Process ownership stays native.
use super::{Stamp, TAIL_BYTES};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const MAX_PROJECTS: usize = 4096;
const MAX_WORKERS: usize = 256;
const MAX_CACHE: usize = 4096;

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Session {
    pub session_id: String,
    pub started: f64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub root: String,
    pub sessions: Vec<Session>,
    pub now: f64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Working,
    Unknown,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Batch {
    pub results: Vec<Option<State>>,
    pub reads: usize,
    pub cache_hits: usize,
}
#[derive(Clone, Debug, Default)]
struct Lifecycle {
    uncertain: bool,
    timestamp: Option<f64>,
    terminal: bool,
}
impl Lifecycle {
    fn state(&self, now: f64, modified: f64) -> Option<State> {
        if self.uncertain {
            return Some(State::Unknown);
        }
        let time = self.timestamp?;
        if time > now + 5.0 {
            return Some(State::Unknown);
        }
        if self.terminal {
            return None;
        }
        Some(
            if (-5.0..=120.0).contains(&(now - time)) && (-5.0..=120.0).contains(&(now - modified))
            {
                State::Working
            } else {
                State::Unknown
            },
        )
    }
}
#[derive(Clone)]
struct Cached {
    stamp: Stamp,
    session_id: String,
    started: f64,
    lifecycle: Lifecycle,
}
#[derive(Default)]
pub struct Worker {
    cache: HashMap<PathBuf, Cached>,
}
fn safe_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}
fn uuid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}
fn parse(bytes: &[u8], session: &Session, agent_id: &str) -> Lifecycle {
    let text = String::from_utf8_lossy(bytes);
    let mut identified = false;
    for line in text.lines().rev() {
        let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        identified |= event["sessionId"].is_string() && event["agentId"].is_string();
        if event["sessionId"].as_str() != Some(&session.session_id)
            || event["agentId"].as_str() != Some(agent_id)
            || event["isSidechain"].as_bool() != Some(true)
        {
            continue;
        }
        let Some(kind @ ("assistant" | "user")) = event["type"].as_str() else {
            continue;
        };
        let Some(stamp) = event["timestamp"].as_str() else {
            continue;
        };
        let Ok(time) = chrono::DateTime::parse_from_rfc3339(stamp) else {
            continue;
        };
        let timestamp = time.timestamp() as f64 + f64::from(time.timestamp_subsec_nanos()) / 1e9;
        if timestamp < session.started - 2.0 || !event["message"].is_object() {
            continue;
        }
        let message = &event["message"];
        let terminal = (kind == "assistant"
            && matches!(
                message["stop_reason"].as_str(),
                Some("end_turn" | "stop_sequence")
            ))
            || (kind == "user"
                && event["toolEndsTurn"].as_bool() == Some(true)
                && message["content"].as_array().is_some_and(|blocks| {
                    blocks
                        .iter()
                        .any(|b| b["type"].as_str() == Some("tool_result"))
                }));
        return Lifecycle {
            uncertain: false,
            timestamp: Some(timestamp),
            terminal,
        };
    }
    Lifecycle {
        uncertain: !identified && !text.trim().is_empty(),
        ..Lifecycle::default()
    }
}
fn directory(path: &Path) -> io::Result<bool> {
    Ok(fs::symlink_metadata(path)?.file_type().is_dir())
}
fn merge(a: Option<State>, b: Option<State>) -> Option<State> {
    if a == Some(State::Working) || b == Some(State::Working) {
        Some(State::Working)
    } else {
        a.or(b)
    }
}
impl Worker {
    fn inspect(
        &mut self,
        path: &Path,
        session: &Session,
        agent: &str,
        now: f64,
        reads: &mut usize,
        hits: &mut usize,
    ) -> io::Result<Option<State>> {
        let mut file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(path)?;
        let meta = file.metadata()?;
        if !meta.is_file() {
            return Err(io::Error::other("not a regular file"));
        }
        let modified = meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9;
        if modified < session.started - 2.0 {
            self.cache.remove(path);
            return Ok(None);
        }
        let stamp = Stamp::from(&meta);
        if let Some(cached) = self.cache.get(path)
            && cached.stamp == stamp
            && cached.session_id == session.session_id
            && cached.started == session.started
        {
            *hits += 1;
            return Ok(cached.lifecycle.state(now, modified));
        }
        self.cache.remove(path);
        file.seek(SeekFrom::Start(meta.len().saturating_sub(TAIL_BYTES)))?;
        let mut bytes = Vec::new();
        (&mut file).take(TAIL_BYTES).read_to_end(&mut bytes)?;
        *reads += 1;
        let lifecycle = parse(&bytes, session, agent);
        if Stamp::from(&file.metadata()?) != stamp {
            return Err(io::Error::other("changed during read"));
        }
        let state = lifecycle.state(now, modified);
        if self.cache.len() < MAX_CACHE {
            self.cache.insert(
                path.to_owned(),
                Cached {
                    stamp,
                    session_id: session.session_id.clone(),
                    started: session.started,
                    lifecycle,
                },
            );
        }
        Ok(state)
    }
    pub fn scan(&mut self, request: Request) -> io::Result<Batch> {
        if !Path::new(&request.root).is_absolute()
            || request.root.len() > 16 * 1024
            || request.sessions.len() > 256
            || !request.now.is_finite()
            || request
                .sessions
                .iter()
                .any(|s| !uuid(&s.session_id) || !s.started.is_finite() || s.started <= 0.0)
        {
            return Err(io::Error::other("invalid Claude request"));
        }
        let deadline = Instant::now() + Duration::from_millis(1200);
        let mut batch = Batch {
            results: vec![None; request.sessions.len()],
            reads: 0,
            cache_hits: 0,
        };
        let mut visited = HashSet::new();
        // Discover projects once per batch, not once per open Claude chat.
        let index = (|| -> io::Result<Vec<PathBuf>> {
            let root = Path::new(&request.root);
            match directory(root) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
                Ok(true) => (),
                _ => return Err(io::Error::other("project directory unavailable")),
            }
            let mut projects = Vec::new();
            for (count, entry) in fs::read_dir(root)?.enumerate() {
                if count >= MAX_PROJECTS || Instant::now() >= deadline {
                    return Err(io::Error::other("project scan incomplete"));
                }
                let entry = entry?;
                if entry.file_type()?.is_dir() {
                    projects.push(entry.path());
                }
            }
            Ok(projects)
        })();
        if let Ok(projects) = index {
            for (index, session) in request.sessions.iter().enumerate() {
                let mut state = None;
                let scan = (|| -> io::Result<()> {
                    let mut workers = 0;
                    for project in &projects {
                        if Instant::now() >= deadline {
                            return Err(io::Error::other("session scan incomplete"));
                        }
                        let parent = project.join(&session.session_id);
                        match directory(&parent) {
                            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                            Ok(true) => (),
                            _ => return Err(io::Error::other("session directory unavailable")),
                        }
                        let folder = parent.join("subagents");
                        match directory(&folder) {
                            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                            Ok(true) => (),
                            _ => return Err(io::Error::other("worker directory unavailable")),
                        }
                        for (entries, file) in fs::read_dir(folder)?.enumerate() {
                            if entries >= 4096 || Instant::now() >= deadline {
                                return Err(io::Error::other("worker scan incomplete"));
                            }
                            let path = file?.path();
                            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                                continue;
                            };
                            let Some(agent) = name
                                .strip_prefix("agent-")
                                .and_then(|s| s.strip_suffix(".jsonl"))
                            else {
                                continue;
                            };
                            if !safe_id(agent) {
                                continue;
                            }
                            workers += 1;
                            if workers > MAX_WORKERS {
                                return Err(io::Error::other("worker limit reached"));
                            }
                            visited.insert(path.clone());
                            state = merge(
                                state,
                                self.inspect(
                                    &path,
                                    session,
                                    agent,
                                    request.now,
                                    &mut batch.reads,
                                    &mut batch.cache_hits,
                                )
                                .unwrap_or(Some(State::Unknown)),
                            );
                        }
                    }
                    Ok(())
                })();
                batch.results[index] = if scan.is_err() {
                    merge(state, Some(State::Unknown))
                } else {
                    state
                };
            }
        } else {
            batch.results.fill(Some(State::Unknown));
        }
        self.cache.retain(|path, _| visited.contains(path));
        Ok(batch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    const SID: &str = "11111111-2222-4333-8444-555555555555";
    fn session() -> Session {
        Session {
            session_id: SID.into(),
            started: 1_800_000_000.0 - 600.0,
        }
    }
    fn event(seconds: i64, terminal: bool) -> serde_json::Value {
        json!({"sessionId": SID, "agentId": "worker", "isSidechain": true, "type": "assistant",
            "timestamp": chrono::DateTime::from_timestamp(seconds, 0).unwrap().to_rfc3339(),
            "message": {"stop_reason": if terminal { "end_turn" } else { "tool_use" }}})
    }
    #[test]
    fn ownership_terminal_handback_and_live_ages() {
        let now = 1_800_000_000.0;
        let parse_state = |e: serde_json::Value, age: f64| {
            parse(e.to_string().as_bytes(), &session(), "worker").state(now + age, now)
        };
        assert_eq!(
            parse_state(event(now as i64, false), 0.0),
            Some(State::Working)
        );
        assert_eq!(
            parse_state(event(now as i64, false), 121.0),
            Some(State::Unknown)
        );
        assert_eq!(parse_state(event(now as i64, true), 900.0), None);
        assert_eq!(
            parse_state(event(now as i64 + 100, true), 0.0),
            Some(State::Unknown)
        );
        assert_eq!(parse_state(event(now as i64 - 900, false), 0.0), None);
        let mut handback = event(now as i64 - 300, false);
        handback["type"] = json!("user");
        handback["toolEndsTurn"] = json!(true);
        handback["message"] =
            json!({"content": [{"type": "tool_result", "content": "PRIVATE BODY"}]});
        assert_eq!(parse_state(handback.clone(), 0.0), None);
        for flag in [json!(1), json!("true"), json!(false), json!(null)] {
            handback["toolEndsTurn"] = flag;
            assert_eq!(parse_state(handback.clone(), 0.0), Some(State::Unknown));
        }
        handback["sessionId"] = json!("foreign");
        assert_eq!(parse_state(handback, 0.0), None);
        assert_eq!(
            parse(b"partial", &session(), "worker").state(now, now),
            Some(State::Unknown)
        );
    }
    #[test]
    fn bounded_discovery_cache_aging_mutation_and_incarnation() {
        let fixture = crate::tests::Fixture::new();
        let root = &fixture.0;
        for i in 0..270 {
            fs::create_dir(root.join(i.to_string())).unwrap();
        }
        let now = 1_800_000_000.0;
        let request = |age: f64, started: f64| Request {
            root: root.to_string_lossy().into(),
            sessions: vec![Session {
                session_id: SID.into(),
                started,
            }],
            now: now + age,
        };
        let mut worker = Worker::default();
        assert_eq!(
            worker.scan(request(0.0, now - 600.0)).unwrap().results,
            [None]
        );
        let folder = root.join("269").join(SID).join("subagents");
        fs::create_dir_all(&folder).unwrap();
        let path = folder.join("agent-worker.jsonl");
        let write = |terminal| {
            fs::write(&path, event(now as i64, terminal).to_string()).unwrap();
            fs::File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(now as u64))
                .unwrap();
        };
        write(false);
        assert_eq!(
            worker.scan(request(0.0, now - 600.0)).unwrap().results,
            [Some(State::Working)]
        );
        let warm = worker.scan(request(121.0, now - 600.0)).unwrap();
        assert_eq!(warm.results, [Some(State::Unknown)]);
        assert_eq!(warm.cache_hits, 1);
        assert_eq!(warm.reads, 0);
        write(true);
        let done = worker.scan(request(121.0, now - 600.0)).unwrap();
        assert_eq!(done.results, [None]);
        assert_eq!(done.reads, 1);
        assert_eq!(
            worker.scan(request(121.0, now + 100.0)).unwrap().results,
            [None]
        );
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink("/dev/null", &path).unwrap();
        assert_eq!(
            worker.scan(request(0.0, now - 600.0)).unwrap().results,
            [Some(State::Unknown)]
        );
        fs::remove_file(&path).unwrap();
        assert_eq!(
            worker.scan(request(0.0, now - 600.0)).unwrap().results,
            [None]
        );
        for i in 270..=MAX_PROJECTS {
            fs::create_dir(root.join(i.to_string())).unwrap();
        }
        assert_eq!(
            worker.scan(request(0.0, now - 600.0)).unwrap().results,
            [Some(State::Unknown)]
        );
    }
}
