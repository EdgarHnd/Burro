//! A read-only, persistent Codex metadata index. No transcript bodies or credentials.
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io;
use std::path::Path;
use std::time::{Duration, Instant};

const MAX_ROWS: usize = 20_000;
const MAX_BYTES: usize = 6 * 1024 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub path: String,
    pub revision: Option<u64>,
    pub scope: Option<Scope>,
}

#[derive(Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Scope {
    since: i64,
    ids: Vec<String>,
}

#[derive(Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    threads: Vec<BTreeMap<String, String>>,
    roots: Vec<String>,
    attachments: Vec<BTreeMap<String, String>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Batch {
    revision: u64,
    snapshot: Option<Snapshot>,
    delta: Option<Delta>,
    queried: bool,
}

// Active chats update frequently. Send changed rows plus their exact order,
// rather than serializing every historical title on every relevant commit.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Delta {
    base_revision: u64,
    threads: Vec<BTreeMap<String, String>>,
    order: Vec<String>,
    roots: Vec<String>,
    attachments: Vec<BTreeMap<String, String>>,
}

impl Delta {
    fn between(before: &Snapshot, after: &Snapshot, base_revision: u64) -> Option<Self> {
        let mut previous = HashMap::new();
        for row in &before.threads {
            let id = row.get("id")?;
            if id.is_empty() || previous.insert(id, row).is_some() {
                return None;
            }
        }
        let mut seen = HashSet::new();
        let mut threads = Vec::new();
        let mut order = Vec::with_capacity(after.threads.len());
        for row in &after.threads {
            let id = row.get("id")?;
            if id.is_empty() || !seen.insert(id) {
                return None;
            }
            order.push(id.clone());
            if previous.get(id).copied() != Some(row) {
                threads.push(row.clone());
            }
        }
        Some(Self {
            base_revision,
            threads,
            order,
            roots: after.roots.clone(),
            attachments: after.attachments.clone(),
        })
    }
}

struct Index {
    path: String,
    identity: crate::Stamp,
    scope: Option<Scope>,
    connection: Connection,
    data_version: i64,
    snapshot: Snapshot,
}

#[derive(Default)]
pub struct Worker {
    index: Option<Index>,
    revision: u64,
}

fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "metadata unavailable")
}

fn identity(path: &str) -> io::Result<crate::Stamp> {
    if !Path::new(path).is_absolute() || path.len() > 16 * 1024 {
        return Err(invalid());
    }
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_file() {
        return Err(invalid());
    }
    Ok(crate::Stamp::from(&meta))
}

fn rows(db: &Connection, sql: &str) -> rusqlite::Result<Vec<BTreeMap<String, String>>> {
    rows_with_params(db, sql, &[])
}

fn rows_with_params(
    db: &Connection,
    sql: &str,
    params: &[&dyn rusqlite::ToSql],
) -> rusqlite::Result<Vec<BTreeMap<String, String>>> {
    let mut statement = db.prepare(sql)?;
    let names = statement
        .column_names()
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let mut cursor = statement.query(params)?;
    let mut result = Vec::new();
    let mut bytes = 0;
    while let Some(row) = cursor.next()? {
        if result.len() >= MAX_ROWS {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let mut record = BTreeMap::new();
        for (column, name) in names.iter().enumerate() {
            use rusqlite::types::ValueRef;
            let value = match row.get_ref(column)? {
                ValueRef::Null => continue,
                ValueRef::Text(text) => String::from_utf8_lossy(text).into_owned(),
                ValueRef::Integer(number) => number.to_string(),
                ValueRef::Real(number) => number.to_string(),
                ValueRef::Blob(_) => return Err(rusqlite::Error::InvalidQuery),
            };
            bytes += value.len();
            if bytes > MAX_BYTES {
                return Err(rusqlite::Error::InvalidQuery);
            }
            record.insert(name.clone(), value);
        }
        result.push(record);
    }
    Ok(result)
}

fn read(db: &Connection, scope: Option<&Scope>) -> rusqlite::Result<Snapshot> {
    // One consistent snapshot across threads, roots, and attachments. Do not hold
    // a read transaction between refreshes (which would pin the provider's WAL).
    let transaction = db.unchecked_transaction()?;
    let columns: HashSet<_> = rows(&transaction, "PRAGMA table_info(threads)")?
        .into_iter()
        .filter_map(|mut row| row.remove("name"))
        .collect();
    let pinned = if columns.contains("is_pinned") {
        "is_pinned"
    } else {
        "0 AS is_pinned"
    };
    let name = if columns.contains("name") {
        "name"
    } else {
        "NULL AS name"
    };
    let source = if columns.contains("source") {
        "source"
    } else {
        "NULL AS source"
    };
    let selection = format!(
        "SELECT id,cwd,title,updated_at,rollout_path,{pinned},{name},{source} FROM threads WHERE archived=0"
    );
    let threads = if let Some(scope) = scope {
        let ids = serde_json::to_string(&scope.ids).map_err(|_| rusqlite::Error::InvalidQuery)?;
        let pin_filter = if columns.contains("is_pinned") {
            "is_pinned=1"
        } else {
            "0"
        };
        let parent = if columns.contains("source") {
            "CASE WHEN json_valid(t.source) THEN json_extract(t.source,'$.subagent.thread_spawn.parent_thread_id') END"
        } else {
            "NULL"
        };
        // Keep ancestors even when an older parent has not updated its own row.
        // UNION bounds cycles; provider metadata remains read-only.
        let sql = format!("WITH RECURSIVE selected(id) AS (
            SELECT id FROM threads WHERE archived=0 AND (updated_at>=?1 OR {pin_filter} OR id IN (SELECT value FROM json_each(?2)))
            UNION SELECT {parent} FROM threads t JOIN selected s ON t.id=s.id WHERE t.archived=0
        ) {selection} AND id IN (SELECT id FROM selected) ORDER BY updated_at DESC");
        rows_with_params(&transaction, &sql, &[&scope.since, &ids])?
    } else {
        rows(
            &transaction,
            &format!("{selection} ORDER BY updated_at DESC"),
        )?
    };
    let tables: HashSet<_> = rows(
        &transaction,
        "SELECT name FROM sqlite_master WHERE type='table'",
    )?
    .into_iter()
    .filter_map(|mut row| row.remove("name"))
    .collect();
    let roots = if tables.contains("project_roots") {
        rows(&transaction, "SELECT path FROM project_roots")?
            .into_iter()
            .filter_map(|mut row| row.remove("path"))
            .collect()
    } else {
        Vec::new()
    };
    let attachments = if tables.contains("thread_attachments") {
        rows(
            &transaction,
            "SELECT thread_id,identity_key,payload FROM thread_attachments WHERE attachment_type='worktree'",
        )?
    } else {
        Vec::new()
    };
    transaction.commit()?;
    Ok(Snapshot {
        threads,
        roots,
        attachments,
    })
}

impl Worker {
    pub fn scan(&mut self, request: Request) -> io::Result<Batch> {
        let result = self.scan_inner(request);
        // Failed reads never serve a previous successful snapshot.
        if result.is_err() {
            self.index = None;
        }
        result
    }

    fn scan_inner(&mut self, request: Request) -> io::Result<Batch> {
        if request.scope.as_ref().is_some_and(|scope| {
            scope.ids.len() > 2048 || scope.ids.iter().any(|id| id.is_empty() || id.len() > 128)
        }) {
            return Err(invalid());
        }
        let before = identity(&request.path)?;
        let fresh = !self.index.as_ref().is_some_and(|index| {
            index.path == request.path && index.identity == before && index.scope == request.scope
        });
        if fresh {
            self.index = None;
            let connection = Connection::open_with_flags(
                &request.path,
                OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )
            .map_err(|_| invalid())?;
            connection
                .busy_timeout(Duration::from_millis(200))
                .map_err(|_| invalid())?;
            connection
                .set_limit(
                    rusqlite::limits::Limit::SQLITE_LIMIT_LENGTH,
                    MAX_BYTES as i32,
                )
                .map_err(|_| invalid())?;
            self.index = Some(Index {
                path: request.path.clone(),
                identity: before.clone(),
                scope: request.scope.clone(),
                connection,
                data_version: -1,
                snapshot: Snapshot::default(),
            });
        }
        let index = self.index.as_mut().ok_or_else(invalid)?;
        let deadline = Instant::now() + Duration::from_millis(1200);
        index
            .connection
            .progress_handler(1000, Some(move || Instant::now() >= deadline));
        let version: i64 = index
            .connection
            .query_row("PRAGMA data_version", [], |row| row.get(0))
            .map_err(|_| invalid())?;
        let queried = fresh || index.data_version != version;
        let mut delta = None;
        if queried {
            let snapshot = read(&index.connection, index.scope.as_ref()).map_err(|_| invalid())?;
            if serde_json::to_vec(&snapshot).map_err(|_| invalid())?.len() > MAX_BYTES {
                return Err(invalid());
            }
            if fresh || snapshot != index.snapshot {
                if !fresh && request.revision == Some(self.revision) {
                    delta = Delta::between(&index.snapshot, &snapshot, self.revision);
                    if let Some(change) = &delta
                        && serde_json::to_vec(change).map_err(|_| invalid())?.len() > MAX_BYTES
                    {
                        delta = None;
                    }
                }
                self.revision = self.revision.checked_add(1).ok_or_else(invalid)?;
                index.snapshot = snapshot;
            }
            index.data_version = version;
        }
        if identity(&request.path)? != before {
            return Err(invalid());
        }
        Ok(Batch {
            revision: self.revision,
            queried,
            // A new worker/connection always sends a full snapshot, even if an
            // old client's revision happens to match its initial counter.
            snapshot: (delta.is_none() && (fresh || request.revision != Some(self.revision)))
                .then(|| index.snapshot.clone()),
            delta,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::Fixture;

    fn database(path: &Path) -> Connection {
        let db = Connection::open(path).unwrap();
        db.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT, cwd TEXT, title TEXT, updated_at INTEGER, rollout_path TEXT, archived INTEGER); INSERT INTO threads VALUES ('one','/tmp','Chat',1,'/tmp/log',0);").unwrap();
        db
    }
    fn request(path: &Path, revision: Option<u64>) -> Request {
        Request {
            path: path.to_str().unwrap().into(),
            revision,
            scope: None,
        }
    }
    #[test]
    fn skips_unchanged_metadata_and_sees_wal_commits_archives_and_schema_changes() {
        let fixture = Fixture::new();
        let path = fixture.0.join("state.sqlite");
        let db = database(&path);
        let mut worker = Worker::default();
        let first = worker.scan(request(&path, None)).unwrap();
        assert!(first.queried);
        assert_eq!(first.snapshot.unwrap().threads.len(), 1);
        let warm = worker.scan(request(&path, Some(first.revision))).unwrap();
        assert!(!warm.queried);
        assert!(warm.snapshot.is_none());
        db.execute_batch("ALTER TABLE threads ADD COLUMN name TEXT; UPDATE threads SET name='Renamed'; CREATE TABLE project_roots(path TEXT); INSERT INTO project_roots VALUES('/project');").unwrap();
        let changed = worker.scan(request(&path, Some(first.revision))).unwrap();
        assert!(changed.queried);
        assert!(changed.snapshot.is_none());
        let delta = changed.delta.unwrap();
        assert_eq!(delta.base_revision, first.revision);
        assert_eq!(delta.threads[0]["name"], "Renamed");
        assert_eq!(delta.roots, ["/project"]);
        db.execute_batch("UPDATE threads SET archived=1").unwrap();
        assert!(
            worker
                .scan(request(&path, Some(changed.revision)))
                .unwrap()
                .delta
                .unwrap()
                .order
                .is_empty()
        );
    }
    #[test]
    fn active_chat_updates_do_not_resend_historical_titles() {
        let fixture = Fixture::new();
        let path = fixture.0.join("state.sqlite");
        let db = database(&path);
        let title = "historical title ".repeat(100);
        for i in 0..300 {
            db.execute(
                "INSERT INTO threads VALUES (?1,'/tmp',?2,0,'/tmp/log',0)",
                rusqlite::params![format!("history-{i}"), title],
            )
            .unwrap();
        }
        let mut worker = Worker::default();
        let first = worker.scan(request(&path, None)).unwrap();
        let full_size = serde_json::to_vec(&first).unwrap().len();
        db.execute_batch("UPDATE threads SET title='Active',updated_at=10 WHERE id='history-0'; UPDATE threads SET archived=1 WHERE id='one'; INSERT INTO threads VALUES('new','/tmp','New',11,'/tmp/log',0);").unwrap();
        let changed = worker.scan(request(&path, Some(first.revision))).unwrap();
        assert!(changed.snapshot.is_none());
        let delta = changed.delta.as_ref().unwrap();
        assert_eq!(delta.threads.len(), 2);
        assert_eq!(delta.order.len(), 301);
        assert_eq!(&delta.order[..2], ["new", "history-0"]);
        assert!(!delta.order.iter().any(|id| id == "one"));
        assert!(serde_json::to_vec(&changed).unwrap().len() < full_size / 10);
        // An out-of-date client must recover with a full, current snapshot.
        let recovered = worker.scan(request(&path, Some(first.revision))).unwrap();
        assert!(recovered.delta.is_none());
        assert_eq!(recovered.snapshot.unwrap().threads.len(), 301);
    }
    #[test]
    fn replacement_deletion_restart_and_failures_cannot_reuse_stale_rows() {
        let fixture = Fixture::new();
        let path = fixture.0.join("state.sqlite");
        drop(database(&path));
        let mut worker = Worker::default();
        let first = worker.scan(request(&path, None)).unwrap();
        let replacement = fixture.0.join("replacement.sqlite");
        let db = database(&replacement);
        db.execute_batch("DELETE FROM threads").unwrap();
        drop(db);
        fs::rename(&replacement, &path).unwrap();
        assert!(
            worker
                .scan(request(&path, Some(first.revision)))
                .unwrap()
                .snapshot
                .unwrap()
                .threads
                .is_empty()
        );
        assert!(
            Worker::default()
                .scan(request(&path, Some(1)))
                .unwrap()
                .snapshot
                .is_some()
        );
        fs::remove_file(&path).unwrap();
        assert!(worker.scan(request(&path, Some(2))).is_err());
        assert!(worker.index.is_none());
        fs::write(&path, b"broken").unwrap();
        assert!(worker.scan(request(&path, None)).is_err());
    }
    #[test]
    fn ignores_unrelated_writes_and_preserves_read_only_database() {
        let fixture = Fixture::new();
        let path = fixture.0.join("state.sqlite");
        let db = database(&path);
        let mut worker = Worker::default();
        let first = worker.scan(request(&path, None)).unwrap();
        db.execute_batch("CREATE TABLE unrelated(value TEXT)")
            .unwrap();
        let result = worker.scan(request(&path, Some(first.revision))).unwrap();
        assert!(result.queried);
        assert!(result.snapshot.is_none());
        assert!(
            worker
                .index
                .as_ref()
                .unwrap()
                .connection
                .execute("DELETE FROM threads", [])
                .is_err()
        );
        let missing = fixture.0.join("missing.sqlite");
        assert!(worker.scan(request(&missing, None)).is_err());
        assert!(!missing.exists());
    }

    #[test]
    fn live_scope_keeps_pins_explicit_ids_and_ancestor_chains() {
        let fixture = Fixture::new();
        let path = fixture.0.join("state.sqlite");
        let db = database(&path);
        db.execute_batch("ALTER TABLE threads ADD COLUMN is_pinned INTEGER DEFAULT 0; ALTER TABLE threads ADD COLUMN source TEXT;").unwrap();
        let grandparent = "11111111-1111-4111-8111-111111111111";
        let parent = "22222222-2222-4222-8222-222222222222";
        let child = "33333333-3333-4333-8333-333333333333";
        let unusual = "unread' OR 1=1 --";
        for (id, updated, pinned, source) in [
            (grandparent, 1, 0, "cli".to_string()),
            (
                parent,
                1,
                0,
                serde_json::json!({"subagent":{"thread_spawn":{"parent_thread_id":grandparent}}})
                    .to_string(),
            ),
            (
                child,
                101,
                0,
                serde_json::json!({"subagent":{"thread_spawn":{"parent_thread_id":parent}}})
                    .to_string(),
            ),
            ("pinned", 1, 1, "not-json".to_string()),
            ("locked", 1, 0, "cli".to_string()),
            (unusual, 1, 0, "cli".to_string()),
        ] {
            db.execute(
                "INSERT INTO threads VALUES (?1,'/tmp','Chat',?2,'/tmp/log',0,?3,?4)",
                rusqlite::params![id, updated, pinned, source],
            )
            .unwrap();
        }
        let mut worker = Worker::default();
        let full = worker.scan(request(&path, None)).unwrap();
        assert_eq!(full.snapshot.unwrap().threads.len(), 7);
        let mut live = request(&path, Some(full.revision));
        live.scope = Some(Scope {
            since: 100,
            ids: vec!["locked".into(), unusual.into()],
        });
        let result = worker.scan(live).unwrap();
        let ids: HashSet<_> = result
            .snapshot
            .unwrap()
            .threads
            .into_iter()
            .map(|mut row| row.remove("id").unwrap())
            .collect();
        assert_eq!(ids.len(), 6);
        assert!(!ids.contains("one"));
        for id in [grandparent, parent, child, "pinned", "locked", unusual] {
            assert!(ids.contains(id));
        }
        let all = worker.scan(request(&path, Some(result.revision))).unwrap();
        assert_eq!(all.snapshot.unwrap().threads.len(), 7);
    }
}
