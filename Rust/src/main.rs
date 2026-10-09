//! Private, parent-owned stdio worker. Reads only the files requested by Swift.
//! No network, provider credentials, or persistent storage.
mod claude;
mod completed;
mod status_policy;
mod usage;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{Metadata, OpenOptions};
use std::io::{self, BufRead, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

const VERSION: u32 = 3;
const MAX_REQUEST: usize = 2 * 1024 * 1024;
const MAX_PATHS: usize = 2048;
const TAIL_BYTES: u64 = 512 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    id: String,
    paths: Vec<String>,
    claude: Option<claude::Request>,
    usage: Option<usage::Request>,
    completed: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum EventState {
    Working,
    Idle,
    Waiting,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
struct Evidence {
    readable: bool,
    modified: Option<f64>,
    last: Option<EventState>,
    completed: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    version: u32,
    id: String,
    results: Vec<Evidence>,
    reads: usize,
    cache_hits: usize,
    claude: Option<claude::Batch>,
    usage: Option<usage::Batch>,
    completed: Option<completed::Batch>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Stamp {
    device: u64,
    inode: u64,
    size: u64,
    modified: (i64, i64),
    changed: (i64, i64),
}

impl Stamp {
    fn from(meta: &Metadata) -> Self {
        Self {
            device: meta.dev(),
            inode: meta.ino(),
            size: meta.len(),
            modified: (meta.mtime(), meta.mtime_nsec()),
            changed: (meta.ctime(), meta.ctime_nsec()),
        }
    }
}

#[derive(Default)]
struct Worker {
    // Only lifecycle summaries are retained. Never cache raw transcript bytes.
    cache: HashMap<String, (Stamp, Evidence)>,
    claude: claude::Worker,
    usage: usage::Worker,
    completed: completed::Worker,
}

fn parse_tail(bytes: &[u8]) -> (Option<EventState>, bool) {
    let text = String::from_utf8_lossy(bytes);
    for line in text.split('\n').rev().filter(|line| !line.is_empty()) {
        let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if event.get("type").and_then(|v| v.as_str()) != Some("event_msg") {
            continue;
        }
        let kind = event
            .get("payload")
            .and_then(|v| v.get("type"))
            .and_then(|v| v.as_str());
        if let Some((state, completed)) = kind.and_then(status_policy::codex_event) {
            return (Some(state), completed);
        }
    }
    (None, false)
}

impl Worker {
    fn inspect(&mut self, path: &str, reads: &mut usize, hits: &mut usize) -> Evidence {
        let unavailable = Evidence::default();
        if !Path::new(path).is_absolute() || path.len() > 16 * 1024 {
            return unavailable;
        }
        // O_NONBLOCK ensures a FIFO cannot hang the worker before fstat. Reject
        // final-component symlinks and non-regular files before reading anything.
        let Ok(mut file) = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(path)
        else {
            self.cache.remove(path);
            return unavailable;
        };
        let Ok(meta) = file.metadata() else {
            return unavailable;
        };
        if !meta.is_file() {
            self.cache.remove(path);
            return unavailable;
        }
        let stamp = Stamp::from(&meta);
        if let Some((cached_stamp, evidence)) = self.cache.get(path)
            && *cached_stamp == stamp
        {
            *hits += 1;
            return evidence.clone();
        }
        self.cache.remove(path);
        if file
            .seek(SeekFrom::Start(meta.len().saturating_sub(TAIL_BYTES)))
            .is_err()
        {
            return unavailable;
        }
        let mut bytes = Vec::new();
        if (&mut file)
            .take(TAIL_BYTES)
            .read_to_end(&mut bytes)
            .is_err()
        {
            return unavailable;
        }
        *reads += 1;
        let (last, completed) = parse_tail(&bytes);
        // Appends, truncation, and in-place rewrites during this read are uncertain.
        if file
            .metadata()
            .map(|m| Stamp::from(&m) != stamp)
            .unwrap_or(true)
        {
            return unavailable;
        }
        let evidence = Evidence {
            readable: true,
            modified: Some(meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9),
            last,
            completed,
        };
        self.cache
            .insert(path.to_owned(), (stamp, evidence.clone()));
        evidence
    }

    fn respond(&mut self, request: Request) -> io::Result<Response> {
        if request.version != VERSION
            || request.paths.len() > MAX_PATHS
            || request.id.len() > 128
            || (request.usage.is_some()
                && (request.claude.is_some()
                    || request.completed.is_some()
                    || !request.paths.is_empty()))
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported request",
            ));
        }
        // Keep at most the current request's paths; bound long-running memory use.
        let active: HashSet<&str> = request.paths.iter().map(String::as_str).collect();
        if request.claude.is_none() || !request.paths.is_empty() {
            self.cache.retain(|path, _| active.contains(path.as_str()));
        }
        let mut reads = 0;
        let mut cache_hits = 0;
        let results = request
            .paths
            .iter()
            .map(|path| self.inspect(path, &mut reads, &mut cache_hits))
            .collect();
        Ok(Response {
            version: VERSION,
            id: request.id,
            results,
            reads,
            cache_hits,
            claude: request
                .claude
                .map(|request| self.claude.scan(request))
                .transpose()?,
            usage: request
                .usage
                .map(|request| self.usage.scan(request))
                .transpose()?,
            completed: request.completed.map(|root| self.completed.scan(root)),
        })
    }
}

fn serve(input: impl BufRead, mut output: impl Write) -> io::Result<()> {
    let mut input = input;
    let mut worker = Worker::default();
    loop {
        let mut line = Vec::new();
        let count = input
            .by_ref()
            .take((MAX_REQUEST + 1) as u64)
            .read_until(b'\n', &mut line)?;
        if count == 0 {
            return Ok(());
        } // Parent exited or closed stdin.
        if count > MAX_REQUEST || line.last() != Some(&b'\n') {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "request too large or incomplete",
            ));
        }
        let request = serde_json::from_slice(&line)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid request"))?;
        serde_json::to_writer(&mut output, &worker.respond(request)?)?;
        output.write_all(b"\n")?;
        output.flush()?;
    }
}

fn main() {
    if std::env::args().skip(1).collect::<Vec<_>>() != ["--stdio-v3"] {
        std::process::exit(2);
    }
    // Protocol failures close the channel. Never print inputs or file contents.
    if serve(io::stdin().lock(), io::stdout().lock()).is_err() {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Cursor;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    fn event(kind: &str) -> String {
        format!(r#"{{"type":"event_msg","payload":{{"type":"{kind}"}}}}"#)
    }
    pub(super) struct Fixture(pub(super) std::path::PathBuf);
    impl Fixture {
        pub(super) fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "burro-rust-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn request(paths: Vec<String>) -> Request {
        Request {
            version: VERSION,
            id: "fixture".into(),
            paths,
            claude: None,
            usage: None,
            completed: None,
        }
    }

    #[test]
    fn lifecycle_ignores_bodies_and_malformed_envelopes() {
        let done = event("task_complete");
        assert_eq!(parse_tail(done.as_bytes()), (Some(EventState::Idle), true));
        for (kind, state) in [
            ("turn_started", EventState::Working),
            ("approval_required", EventState::Waiting),
            ("task_aborted", EventState::Idle),
        ] {
            assert_eq!(
                parse_tail(format!("{done}\n{}\n{{bad", event(kind)).as_bytes()),
                (Some(state), false)
            );
        }
        assert_eq!(
            parse_tail(br#"{"type":"response_item","payload":{"type":"task_complete"}}"#),
            (None, false)
        );
        assert_eq!(
            parse_tail(br#"{"type":"event_msg","payload":{"type":true}}"#),
            (None, false)
        );
    }

    #[test]
    fn caches_only_unchanged_files_and_invalidates_replacements() {
        let fixture = Fixture::new();
        let path = fixture.0.join("log.jsonl");
        let paths = vec![path.to_str().unwrap().to_owned()];
        let mut worker = Worker::default();
        fs::write(&path, event("task_complete")).unwrap();
        assert_eq!(worker.respond(request(paths.clone())).unwrap().reads, 1);
        assert_eq!(
            worker.respond(request(paths.clone())).unwrap().cache_hits,
            1
        );
        fs::write(&path, event("task_started")).unwrap();
        let changed = worker.respond(request(paths.clone())).unwrap();
        assert_eq!(changed.reads, 1);
        assert!(!changed.results[0].completed);
        let replacement = fixture.0.join("new.jsonl");
        fs::write(&replacement, event("turn_complete")).unwrap();
        fs::rename(replacement, &path).unwrap();
        assert!(worker.respond(request(paths.clone())).unwrap().results[0].completed);
        fs::remove_file(&path).unwrap();
        assert!(!worker.respond(request(paths)).unwrap().results[0].readable);
        assert!(worker.cache.is_empty());
    }

    #[test]
    fn rejects_directories_and_symlinks_and_bounds_tail() {
        let fixture = Fixture::new();
        let path = fixture.0.join("log.jsonl");
        fs::write(
            &path,
            format!(
                "{}\n{}",
                event("task_complete"),
                " ".repeat(TAIL_BYTES as usize)
            ),
        )
        .unwrap();
        let link = fixture.0.join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        let response = Worker::default()
            .respond(request(
                [path, link, fixture.0.clone()]
                    .iter()
                    .map(|p| p.to_str().unwrap().into())
                    .collect(),
            ))
            .unwrap();
        assert!(response.results[0].readable);
        assert!(!response.results[0].completed);
        assert!(!response.results[1].readable);
        assert!(!response.results[2].readable);
    }

    #[test]
    fn protocol_is_bounded_versioned_and_closes_on_eof() {
        let mut output = Vec::new();
        serve(
            Cursor::new(b"{\"version\":3,\"id\":\"a\",\"paths\":[]}\n"),
            &mut output,
        )
        .unwrap();
        let value: serde_json::Value = serde_json::from_slice(&output).unwrap();
        assert_eq!(value["id"], "a");
        assert_eq!(value["version"], VERSION);
        assert!(
            serve(
                Cursor::new(b"{\"version\":1,\"id\":\"a\",\"paths\":[]}\n"),
                Vec::new()
            )
            .is_err()
        );
        assert!(serve(Cursor::new(vec![b'x'; MAX_REQUEST + 1]), Vec::new()).is_err());
        assert!(serve(Cursor::new(b"{}"), Vec::new()).is_err());
    }
}

#[cfg(test)]
mod shared_policy_tests {
    #[test]
    fn shared_envelope_fixtures() {
        let fixtures: serde_json::Value =
            serde_json::from_str(include_str!("../../policy/status-fixtures.json")).unwrap();
        for case in fixtures["codex"].as_array().unwrap() {
            let (last, completed) = super::parse_tail(case["tail"].as_str().unwrap().as_bytes());
            assert_eq!(serde_json::to_value(last).unwrap(), case["last"]);
            assert_eq!(completed, case["completed"].as_bool().unwrap());
        }
    }
}
