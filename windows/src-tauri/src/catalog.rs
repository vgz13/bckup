//! Remembers what is on each destination (path, size, date, content hash),
//! so "copy only what's missing" works without re-reading whole drives.

use crate::util::{self, Cancel, CANCELLED};
use rusqlite::{params, Connection};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use walkdir::WalkDir;

#[derive(Clone, Debug)]
pub struct Entry {
    pub rel: String,
    pub size: u64,
    pub mtime: f64,
    pub hash: Option<String>,
}

pub struct Catalog {
    db: Mutex<Connection>,
}

impl Catalog {
    pub fn open(path: &Path) -> Catalog {
        let c = Connection::open(path).unwrap_or_else(|_| Connection::open_in_memory().unwrap());
        let _ = c.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
             CREATE TABLE IF NOT EXISTS dest_files(root TEXT NOT NULL, rel TEXT NOT NULL, size INTEGER NOT NULL,
               mtime REAL NOT NULL, hash TEXT, PRIMARY KEY(root, rel)) WITHOUT ROWID;
             CREATE INDEX IF NOT EXISTS dest_by_size ON dest_files(root, size);",
        );
        Catalog { db: Mutex::new(c) }
    }

    pub fn all(&self, root: &str) -> HashMap<String, Entry> {
        let db = self.db.lock().unwrap();
        let mut out = HashMap::new();
        if let Ok(mut st) = db.prepare("SELECT rel, size, mtime, hash FROM dest_files WHERE root = ?1") {
            let rows = st.query_map(params![root], |r| {
                Ok(Entry { rel: r.get(0)?, size: r.get::<_, i64>(1)? as u64, mtime: r.get(2)?, hash: r.get(3)? })
            });
            if let Ok(rows) = rows {
                for e in rows.flatten() {
                    out.insert(e.rel.clone(), e);
                }
            }
        }
        out
    }

    pub fn candidates(&self, root: &str, size: u64) -> Vec<Entry> {
        let db = self.db.lock().unwrap();
        let mut out = vec![];
        if let Ok(mut st) = db.prepare("SELECT rel, size, mtime, hash FROM dest_files WHERE root = ?1 AND size = ?2") {
            if let Ok(rows) = st.query_map(params![root, size as i64], |r| {
                Ok(Entry { rel: r.get(0)?, size: r.get::<_, i64>(1)? as u64, mtime: r.get(2)?, hash: r.get(3)? })
            }) {
                out.extend(rows.flatten());
            }
        }
        out
    }

    pub fn set_hash(&self, root: &str, rel: &str, hash: &str) {
        let db = self.db.lock().unwrap();
        let _ = db.execute("UPDATE dest_files SET hash = ?1 WHERE root = ?2 AND rel = ?3", params![hash, root, rel]);
    }

    pub fn upsert(&self, root: &str, e: &Entry) {
        let db = self.db.lock().unwrap();
        let _ = db.execute(
            "INSERT OR REPLACE INTO dest_files(root, rel, size, mtime, hash) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![root, e.rel, e.size as i64, e.mtime, e.hash],
        );
    }

    /// Walks the destination folder and brings the catalog up to date.
    pub fn refresh(&self, root: &str, cancel: Option<&Cancel>, mut progress: impl FnMut(usize)) -> Result<(), String> {
        let rootp = Path::new(root);
        if !rootp.is_dir() {
            return Err(format!("Destination not connected: {root}"));
        }
        let existing = self.all(root);
        let mut seen = HashSet::new();
        let mut changed = vec![];
        let mut count = 0;
        for entry in WalkDir::new(rootp).into_iter().filter_entry(|e| !is_hidden(e.file_name())) {
            if cancel.map(|c| c.is_cancelled()).unwrap_or(false) {
                return Err(CANCELLED.into());
            }
            let Ok(entry) = entry else { continue };
            if !entry.file_type().is_file() {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            let rel = util::rel_path(entry.path(), rootp);
            let size = meta.len();
            let mt = util::mtime_of(&meta);
            match existing.get(&rel) {
                Some(e) if e.size == size && (e.mtime - mt).abs() < 0.001 => {}
                _ => changed.push(Entry { rel: rel.clone(), size, mtime: mt, hash: None }),
            }
            seen.insert(rel);
            count += 1;
            if count % 500 == 0 {
                progress(count);
            }
        }
        progress(count);
        let mut db = self.db.lock().unwrap();
        let tx = db.transaction().map_err(|e| e.to_string())?;
        for e in &changed {
            let _ = tx.execute(
                "INSERT OR REPLACE INTO dest_files(root, rel, size, mtime, hash) VALUES(?1, ?2, ?3, ?4, NULL)",
                params![root, e.rel, e.size as i64, e.mtime],
            );
        }
        for rel in existing.keys().filter(|r| !seen.contains(*r)) {
            let _ = tx.execute("DELETE FROM dest_files WHERE root = ?1 AND rel = ?2", params![root, rel]);
        }
        tx.commit().map_err(|e| e.to_string())
    }
}

pub fn is_hidden(name: &std::ffi::OsStr) -> bool {
    let n = name.to_string_lossy();
    n.starts_with('.') || n == "$RECYCLE.BIN" || n == "System Volume Information"
}
