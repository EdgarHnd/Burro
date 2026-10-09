//! Bounded token-counter scans. Cache parsed counters, never transcript text.
use crate::Stamp;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const MAX_FILE: u64 = 32 * 1024 * 1024;
const MAX_BYTES: u64 = 256 * 1024 * 1024;
const MAX_RECORDS: usize = 200_000;
const MAX_VISITED: usize = 20_000;
const MAX_BUCKETS: usize = 512;

#[derive(Clone, Copy, Debug, Deserialize, Hash, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Provider {
    Codex,
    Claude,
    Grok,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub(crate) struct Request {
    pub provider: Provider,
    pub roots: Vec<String>,
    pub now: f64,
    pub day_boundaries: Vec<f64>,
}

#[derive(Clone, Default, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Bucket {
    pub date: f64,
    pub model: String,
    pub input: f64,
    pub cached: f64,
    pub cache_write: f64,
    pub cache_write_hour: f64,
    pub output: f64,
    pub record_count: usize,
}

#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Batch {
    pub buckets: Vec<Bucket>,
    pub partial: bool,
    pub reads: usize,
    pub cache_hits: usize,
    pub bytes_read: u64,
    pub visited: usize,
}

#[derive(Clone, Debug, Hash, PartialEq, Eq)]
enum Key {
    Codex(i64, u64, u64, u64, u64),
    Claude(String, String),
    Grok(String),
}
#[derive(Clone)]
struct Record {
    key: Key,
    date: f64,
    counts: Bucket,
}
impl Record {
    fn total(&self) -> f64 {
        let b = &self.counts;
        b.input + b.cached + b.cache_write + b.cache_write_hour + b.output
    }
}
struct Entry {
    stamp: Stamp,
    records: Arc<Vec<Record>>,
    partial: bool,
    used: u64,
}
#[derive(Default)]
pub(crate) struct Worker {
    cache: HashMap<(Provider, PathBuf), Entry>,
    generation: u64,
    cached_records: usize,
}

fn number(value: &Value) -> Option<f64> {
    value
        .as_f64()
        .filter(|n| n.is_finite() && *n >= 0.0 && *n <= 1e13 && n.fract() == 0.0)
}
fn label(value: &Value, fallback: &str) -> String {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.chars().count() <= 60 && !s.chars().any(char::is_control))
        .unwrap_or(fallback)
        .to_owned()
}
fn timestamp(value: &Value) -> Option<(f64, i64)> {
    let text = value.as_str().filter(|s| s.len() <= 64)?;
    let time = chrono::DateTime::parse_from_rfc3339(text).ok()?;
    Some((
        time.timestamp() as f64 + time.timestamp_subsec_nanos() as f64 / 1e9,
        time.timestamp_nanos_opt()?,
    ))
}
fn claude(object: &Value) -> Option<Record> {
    if object["type"] != "assistant" {
        return None;
    }
    let message = &object["message"];
    let usage = &message["usage"];
    let id = message["id"].as_str()?;
    let scope = object["requestId"]
        .as_str()
        .or_else(|| object["sessionId"].as_str())
        .unwrap_or("");
    let date = timestamp(&object["timestamp"])?.0;
    let input = number(&usage["input_tokens"])?;
    let output = number(&usage["output_tokens"])?;
    let cached = number(&usage["cache_read_input_tokens"])?;
    let writes = number(&usage["cache_creation_input_tokens"])?;
    if output == 0.0 && message["stop_reason"].as_str().is_none() {
        return None;
    }
    let hour = number(&usage["cache_creation"]["ephemeral_1h_input_tokens"]).unwrap_or(0.0);
    if hour > writes {
        return None;
    }
    Some(Record {
        key: Key::Claude(scope.to_owned(), id.to_owned()),
        date,
        counts: Bucket {
            model: label(&message["model"], "Unknown model"),
            input,
            output,
            cached,
            cache_write: writes - hour,
            cache_write_hour: hour,
            ..Bucket::default()
        },
    })
}
fn codex(object: &Value, model: &mut String, previous: &mut Option<f64>) -> Option<Record> {
    let payload = &object["payload"];
    if object["type"] == "turn_context" {
        *model = label(&payload["model"], "Unknown model");
        return None;
    }
    if object["type"] != "event_msg" || payload["type"] != "token_count" {
        return None;
    }
    let info = &payload["info"];
    let usage = &info["last_token_usage"];
    let total = number(&info["total_token_usage"]["total_tokens"])?;
    let (date, nanos) = timestamp(&object["timestamp"])?;
    let input = number(&usage["input_tokens"])?;
    let cached = number(&usage["cached_input_tokens"])?;
    let output = number(&usage["output_tokens"])?;
    if cached > input {
        return None;
    }
    let duplicate = *previous == Some(total);
    *previous = Some(total);
    if duplicate {
        return None;
    }
    Some(Record {
        key: Key::Codex(
            nanos,
            total as u64,
            input as u64,
            cached as u64,
            output as u64,
        ),
        date,
        counts: Bucket {
            model: model.clone(),
            input: input - cached,
            output,
            cached,
            ..Bucket::default()
        },
    })
}

fn parse(
    bytes: &[u8],
    provider: Provider,
    path: &Path,
    modified: f64,
    deadline: Instant,
) -> (Vec<Record>, bool) {
    if provider == Provider::Grok {
        if bytes.len() > 2 * 1024 * 1024 {
            return (vec![], true);
        }
        let Ok(object) = serde_json::from_slice::<Value>(bytes) else {
            return (vec![], true);
        };
        if !object.is_object() {
            return (vec![], true);
        }
        let input = number(&object["totalTokensBeforeCompaction"]).unwrap_or(0.0)
            + number(&object["contextTokensUsed"]).unwrap_or(0.0);
        let records = if input > 0.0 {
            vec![Record {
                key: Key::Grok(
                    path.parent()
                        .and_then(Path::file_name)
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into(),
                ),
                date: modified,
                counts: Bucket {
                    model: label(&object["primaryModelId"], "Grok"),
                    input,
                    ..Bucket::default()
                },
            }]
        } else {
            vec![]
        };
        return (records, false);
    }
    let mut records = Vec::new();
    let mut partial = false;
    let mut model = "Unknown model".to_owned();
    let mut previous = None;
    for line in bytes.split(|b| *b == b'\n').filter(|line| !line.is_empty()) {
        if Instant::now() >= deadline || records.len() >= MAX_RECORDS {
            partial = true;
            break;
        }
        let relevant = if provider == Provider::Claude {
            line.windows(7).any(|s| s == b"\"usage\"")
        } else {
            line.windows(11).any(|s| s == b"token_count")
                || line.windows(12).any(|s| s == b"turn_context")
        };
        if !relevant {
            continue;
        }
        if line.len() > 2 * 1024 * 1024 {
            partial = true;
            continue;
        }
        let Ok(object) = serde_json::from_slice::<Value>(line) else {
            partial = true;
            continue;
        };
        if !object.is_object() {
            partial = true;
            continue;
        }
        let record = if provider == Provider::Claude {
            claude(&object)
        } else {
            codex(&object, &mut model, &mut previous)
        };
        if let Some(record) = record {
            // Maliciously large identifiers must not turn a small counter into a large cache entry.
            if matches!(&record.key, Key::Claude(a, b) if a.len() + b.len() > 1024) {
                partial = true;
                continue;
            }
            records.push(record);
        }
    }
    (records, partial)
}

impl Worker {
    fn remove(&mut self, key: &(Provider, PathBuf)) {
        if let Some(old) = self.cache.remove(key) {
            self.cached_records -= old.records.len();
        }
    }
    fn trim(&mut self) {
        if self.cache.len() <= 8192 && self.cached_records <= MAX_RECORDS {
            return;
        }
        let mut oldest: Vec<_> = self
            .cache
            .iter()
            .map(|(key, entry)| (key.clone(), entry.used))
            .collect();
        oldest.sort_by_key(|(_, used)| *used);
        for (key, _) in oldest {
            if self.cache.len() <= 8192 && self.cached_records <= MAX_RECORDS {
                break;
            }
            self.remove(&key);
        }
    }
    fn file(
        &mut self,
        key: &(Provider, PathBuf),
        deadline: Instant,
        batch: &mut Batch,
    ) -> io::Result<Arc<Vec<Record>>> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(&key.1)?;
        let before = file.metadata()?;
        if !before.is_file()
            || before.uid() != unsafe { libc::geteuid() }
            || before.len() == 0
            || before.len() > MAX_FILE
        {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let stamp = Stamp::from(&before);
        if let Some(entry) = self.cache.get_mut(key).filter(|entry| entry.stamp == stamp) {
            entry.used = self.generation;
            batch.cache_hits += 1;
            batch.partial |= entry.partial;
            return Ok(entry.records.clone());
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        (&file).take(MAX_FILE + 1).read_to_end(&mut bytes)?;
        batch.reads += 1;
        batch.bytes_read += bytes.len() as u64;
        if bytes.len() as u64 != before.len() || Stamp::from(&file.metadata()?) != stamp {
            return Err(io::ErrorKind::Interrupted.into());
        }
        let modified = before.mtime() as f64 + before.mtime_nsec() as f64 / 1e9;
        let (records, partial) = parse(&bytes, key.0, &key.1, modified, deadline);
        let records = Arc::new(records);
        batch.partial |= partial;
        self.remove(key);
        // A timed-out parse is never reused as a complete cached file.
        if Instant::now() < deadline {
            self.cached_records += records.len();
            self.cache.insert(
                key.clone(),
                Entry {
                    stamp,
                    records: records.clone(),
                    partial,
                    used: self.generation,
                },
            );
            self.trim();
        }
        Ok(records)
    }
    pub(crate) fn scan(&mut self, request: Request) -> io::Result<Batch> {
        self.scan_with_budget(request, MAX_BYTES)
    }
    fn scan_with_budget(&mut self, request: Request, byte_budget: u64) -> io::Result<Batch> {
        if request.roots.is_empty()
            || request.roots.len() > 3
            || !request.now.is_finite()
            || !(0.0..=253402300799.0).contains(&request.now)
            || request
                .roots
                .iter()
                .any(|r| !Path::new(r).is_absolute() || r.len() > 16384)
            || request.day_boundaries.len() < 2
            || request.day_boundaries.len() > 34
            || request.day_boundaries.iter().any(|d| !d.is_finite())
            || request.day_boundaries.windows(2).any(|d| d[1] <= d[0])
            || request.day_boundaries[0] > request.now - 30.0 * 86400.0
            || *request.day_boundaries.last().unwrap() <= request.now + 60.0
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        self.generation += 1;
        let deadline = Instant::now() + Duration::from_secs(20);
        let since = request.now - 30.0 * 86400.0;
        let mut batch = Batch::default();
        let mut records: HashMap<Key, Record> = HashMap::new();
        let mut seen = HashSet::new();
        let mut stack: Vec<PathBuf> = request.roots.iter().map(PathBuf::from).collect();
        let mut files = Vec::new();
        while let Some(path) = stack.pop() {
            if batch.visited >= MAX_VISITED || Instant::now() >= deadline {
                batch.partial = true;
                break;
            }
            batch.visited += 1;
            let meta = match fs::symlink_metadata(&path) {
                Ok(m) => m,
                Err(e) => {
                    if e.kind() != io::ErrorKind::NotFound {
                        batch.partial = true;
                    }
                    continue;
                }
            };
            if meta.is_symlink() {
                continue;
            }
            if meta.is_dir() {
                match fs::read_dir(&path) {
                    Ok(entries) => {
                        for entry in entries {
                            if stack.len() + batch.visited >= MAX_VISITED {
                                batch.partial = true;
                                break;
                            }
                            match entry {
                                Ok(e) => stack.push(e.path()),
                                Err(_) => batch.partial = true,
                            }
                        }
                    }
                    Err(_) => batch.partial = true,
                }
                continue;
            }
            let modified = meta.mtime() as f64 + meta.mtime_nsec() as f64 / 1e9;
            let relevant = if request.provider == Provider::Grok {
                path.file_name().is_some_and(|s| s == "signals.json")
            } else {
                path.extension().is_some_and(|s| s == "jsonl")
            };
            if !relevant || !meta.is_file() || modified < since {
                continue;
            }
            files.push((path, meta));
        }
        // Bounded discovery first: recent activity must not lose the read budget
        // to old transcript folders merely because of filesystem enumeration order.
        files.sort_by(|a, b| {
            (b.1.mtime(), b.1.mtime_nsec())
                .cmp(&(a.1.mtime(), a.1.mtime_nsec()))
                .then_with(|| a.0.cmp(&b.0))
        });
        let mut logical_bytes = 0;
        for (path, meta) in files {
            if records.len() >= MAX_RECORDS
                || logical_bytes >= byte_budget
                || Instant::now() >= deadline
            {
                batch.partial = true;
                break;
            }
            let key = (request.provider, path);
            seen.insert(key.clone());
            if meta.len() > MAX_FILE || meta.uid() != unsafe { libc::geteuid() } {
                self.remove(&key);
                batch.partial = true;
                continue;
            }
            logical_bytes += meta.len();
            match self.file(&key, deadline, &mut batch) {
                Ok(parsed) => {
                    for record in parsed
                        .iter()
                        .filter(|r| r.date >= since && r.date <= request.now + 60.0)
                    {
                        if records.len() >= MAX_RECORDS {
                            batch.partial = true;
                            break;
                        }
                        if records
                            .get(&record.key)
                            .is_none_or(|old| old.total() <= record.total())
                        {
                            records.insert(record.key.clone(), record.clone());
                        }
                    }
                }
                Err(_) => {
                    self.remove(&key);
                    batch.partial = true;
                }
            }
        }
        if !batch.partial {
            let stale: Vec<_> = self
                .cache
                .keys()
                .filter(|key| {
                    key.0 == request.provider
                        && request.roots.iter().any(|r| key.1.starts_with(r))
                        && !seen.contains(*key)
                })
                .cloned()
                .collect();
            for key in stale {
                self.remove(&key);
            }
        }
        let mut buckets: BTreeMap<(usize, String), Bucket> = BTreeMap::new();
        for record in records.values() {
            let day = request
                .day_boundaries
                .partition_point(|d| *d <= record.date)
                .saturating_sub(1);
            let key = (day, record.counts.model.clone());
            if !buckets.contains_key(&key) && buckets.len() >= MAX_BUCKETS {
                batch.partial = true;
                continue;
            }
            let bucket = buckets.entry(key).or_insert_with(|| Bucket {
                date: request.day_boundaries[day],
                model: record.counts.model.clone(),
                ..Bucket::default()
            });
            bucket.input += record.counts.input;
            bucket.cached += record.counts.cached;
            bucket.cache_write += record.counts.cache_write;
            bucket.cache_write_hour += record.counts.cache_write_hour;
            bucket.output += record.counts.output;
            bucket.record_count += 1;
        }
        batch.buckets = buckets.into_values().collect();
        Ok(batch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn parse_value(object: Value, provider: Provider) -> (Vec<Record>, bool) {
        parse(
            &serde_json::to_vec(&object).unwrap(),
            provider,
            Path::new("/sessions/test/signals.json"),
            1000.0,
            Instant::now() + Duration::from_secs(1),
        )
    }
    #[test]
    fn numeric_counters_exclude_booleans_negatives_fractions_and_overflow() {
        for value in [
            Value::Bool(true),
            serde_json::json!(-1),
            serde_json::json!(1.5),
            serde_json::json!(1e14),
            Value::Null,
        ] {
            assert!(number(&value).is_none());
        }
        assert_eq!(number(&serde_json::json!(1e13)), Some(1e13));
    }
    #[test]
    fn grok_requires_a_bounded_object_and_adds_compaction_counters() {
        assert!(parse_value(serde_json::json!([]), Provider::Grok).1);
        let (records, partial) = parse_value(
            serde_json::json!({"totalTokensBeforeCompaction": 100, "contextTokensUsed": 50}),
            Provider::Grok,
        );
        assert!(!partial);
        assert_eq!(records[0].total(), 150.0);
        assert!(
            parse(
                &vec![b' '; 2 * 1024 * 1024 + 1],
                Provider::Grok,
                Path::new("/signals.json"),
                0.0,
                Instant::now() + Duration::from_secs(1)
            )
            .1
        );
    }
    #[test]
    fn claude_streaming_null_stop_is_not_a_completed_record() {
        let mut value = serde_json::json!({"type":"assistant", "timestamp":"2026-10-09T00:00:00Z",
            "message":{"id":"one","stop_reason":null,"usage":{"input_tokens":100,"output_tokens":0,
                "cache_read_input_tokens":10,"cache_creation_input_tokens":0}}});
        assert!(claude(&value).is_none());
        value["message"]["stop_reason"] = serde_json::json!("end_turn");
        assert_eq!(claude(&value).unwrap().total(), 110.0);
    }
    #[test]
    fn file_cache_keeps_counters_and_invalidates_replacements() {
        let folder = crate::tests::Fixture::new();
        let path = folder.0.join("signals.json");
        fs::write(&path, br#"{"contextTokensUsed":100}"#).unwrap();
        let key = (Provider::Grok, path.clone());
        let mut worker = Worker::default();
        let mut cold = Batch::default();
        assert_eq!(
            worker
                .file(&key, Instant::now() + Duration::from_secs(1), &mut cold)
                .unwrap()[0]
                .total(),
            100.0
        );
        let mut warm = Batch::default();
        worker
            .file(&key, Instant::now() + Duration::from_secs(1), &mut warm)
            .unwrap();
        assert_eq!((cold.reads, warm.cache_hits, warm.bytes_read), (1, 1, 0));
        let replacement = folder.0.join("replacement");
        fs::write(&replacement, br#"{"contextTokensUsed":200}"#).unwrap();
        fs::rename(replacement, &path).unwrap();
        assert_eq!(
            worker
                .file(&key, Instant::now() + Duration::from_secs(1), &mut warm)
                .unwrap()[0]
                .total(),
            200.0
        );
    }
    #[test]
    fn invalid_boundaries_are_rejected() {
        let request = Request {
            provider: Provider::Codex,
            roots: vec!["/tmp".into()],
            now: 1000.0,
            day_boundaries: vec![0.0, 0.0],
        };
        assert!(Worker::default().scan(request).is_err());
    }
}

#[cfg(test)]
mod budget_tests {
    use super::*;
    #[test]
    fn cold_and_warm_bounded_scans_prioritize_recent_history() {
        let folder = crate::tests::Fixture::new();
        for (name, stamp, count) in [("a-old", 1000, 10), ("z-new", 1900, 20)] {
            let directory = folder.0.join(name);
            fs::create_dir(&directory).unwrap();
            let path = directory.join("signals.json");
            fs::write(&path, format!(r#"{{"contextTokensUsed":{count}}}"#)).unwrap();
            fs::File::options()
                .write(true)
                .open(&path)
                .unwrap()
                .set_times(
                    fs::FileTimes::new()
                        .set_modified(std::time::UNIX_EPOCH + Duration::from_secs(stamp)),
                )
                .unwrap();
        }
        let mut worker = Worker::default();
        for expected_hits in [0, 1] {
            let request = Request {
                provider: Provider::Grok,
                roots: vec![folder.0.to_string_lossy().into()],
                now: 2000.0,
                day_boundaries: vec![-3_000_000.0, 3000.0],
            };
            let result = worker.scan_with_budget(request, 1).unwrap();
            assert!(result.partial);
            assert_eq!(result.buckets.len(), 1);
            assert_eq!(result.buckets[0].input, 20.0);
            assert_eq!(result.cache_hits, expected_hits);
        }
    }
}
