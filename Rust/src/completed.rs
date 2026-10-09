//! Read only Claude desktop completion fields; serde skips unrelated nested content.
use crate::Stamp;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Metadata {
    session_id: Option<String>,
    completed_turns: Option<u64>,
    is_archived: Option<bool>,
}
#[derive(Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Batch {
    pub ids: Vec<String>,
    pub reads: usize,
    pub cache_hits: usize,
    pub partial: bool,
}
#[derive(Default)]
pub(crate) struct Worker {
    cache: HashMap<PathBuf, (Stamp, Option<String>)>,
}

impl Worker {
    pub(crate) fn scan(&mut self, root: String) -> Batch {
        let mut result = Batch::default();
        let root = PathBuf::from(root);
        if !root.is_absolute() || root.as_os_str().len() > 16384 {
            result.partial = true;
            return result;
        }
        let deadline = Instant::now() + Duration::from_millis(1200);
        let mut stack = vec![(root, 0)];
        let mut seen = HashSet::new();
        let mut ids = HashSet::new();
        let mut visited = 0;
        let mut bytes = 0;
        while let Some((path, depth)) = stack.pop() {
            visited += 1;
            if visited > 8192 || bytes > 256 * 1024 * 1024 || Instant::now() >= deadline {
                result.partial = true;
                break;
            }
            let Ok(meta) = fs::symlink_metadata(&path) else {
                continue;
            };
            if meta.is_symlink() {
                continue;
            }
            if meta.is_dir() && depth < 3 {
                let Ok(entries) = fs::read_dir(&path) else {
                    result.partial = true;
                    continue;
                };
                for entry in entries {
                    if stack.len() + visited >= 8192 {
                        result.partial = true;
                        break;
                    }
                    if let Ok(entry) = entry {
                        stack.push((entry.path(), depth + 1));
                    }
                }
                continue;
            }
            if depth != 3
                || !meta.is_file()
                || meta.len() >= 1024 * 1024
                || meta.uid() != unsafe { libc::geteuid() }
                || path.extension().is_none_or(|s| s != "json")
                || path
                    .file_name()
                    .is_none_or(|s| !s.to_string_lossy().starts_with("local_"))
            {
                continue;
            }
            seen.insert(path.clone());
            let stamp = Stamp::from(&meta);
            if let Some((_, id)) = self.cache.get(&path).filter(|(old, _)| *old == stamp) {
                result.cache_hits += 1;
                if let Some(id) = id {
                    ids.insert(id.clone());
                }
                continue;
            }
            self.cache.remove(&path);
            if bytes + meta.len() > 256 * 1024 * 1024 {
                result.partial = true;
                break;
            }
            bytes += meta.len();
            result.reads += 1;
            let Some(id) = Self::read(&path, &stamp) else {
                continue;
            };
            if let Some(id) = &id {
                ids.insert(id.clone());
            }
            self.cache.insert(path, (stamp, id));
        }
        self.cache.retain(|path, _| seen.contains(path));
        result.ids = ids.into_iter().collect();
        result.ids.sort();
        if result.ids.len() > 2048 {
            result.ids.truncate(2048);
            result.partial = true;
        }
        result
    }
    // Outer None is a failed/changed read; inner None is a verified non-completion.
    fn read(path: &Path, expected: &Stamp) -> Option<Option<String>> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(path)
            .ok()?;
        let before = file.metadata().ok()?;
        if !before.is_file() || Stamp::from(&before) != *expected {
            return None;
        }
        let mut bytes = Vec::with_capacity(before.len() as usize);
        (&file).take(1024 * 1024).read_to_end(&mut bytes).ok()?;
        if bytes.len() as u64 != before.len() || Stamp::from(&file.metadata().ok()?) != *expected {
            return None;
        }
        let metadata: Metadata = serde_json::from_slice(&bytes).ok()?;
        Some(
            if metadata.completed_turns.unwrap_or(0) > 0 && metadata.is_archived != Some(true) {
                metadata
                    .session_id
                    .filter(|id| !id.is_empty() && id.len() <= 128)
            } else {
                None
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn completion_cache_clears_on_archive_and_removal() {
        let folder = crate::tests::Fixture::new();
        let org = folder.0.join("account/org");
        fs::create_dir_all(&org).unwrap();
        let file = org.join("local_one.json");
        fs::write(
            &file,
            br#"{"sessionId":"one","completedTurns":2,"unrelated":{"nested":[1,2,3]}}"#,
        )
        .unwrap();
        let mut worker = Worker::default();
        let cold = worker.scan(folder.0.to_string_lossy().into_owned());
        assert_eq!(cold.ids, ["one"]);
        assert_eq!(cold.reads, 1);
        let warm = worker.scan(folder.0.to_string_lossy().into_owned());
        assert_eq!(warm.cache_hits, 1);
        assert_eq!(warm.reads, 0);
        fs::write(
            &file,
            br#"{"sessionId":"one","completedTurns":2,"isArchived":true}"#,
        )
        .unwrap();
        assert!(
            worker
                .scan(folder.0.to_string_lossy().into_owned())
                .ids
                .is_empty()
        );
        fs::remove_file(file).unwrap();
        assert!(
            worker
                .scan(folder.0.to_string_lossy().into_owned())
                .ids
                .is_empty()
        );
    }
}
