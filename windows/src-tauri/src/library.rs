//! Projects (with backup status), Sort downloads, sharing and opening folders.

use crate::catalog::Catalog;
use crate::cloud;
use crate::model::*;
use crate::util::{self, Cancel};
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub fn list_dirs(path: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(path)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .map(|e| e.file_name().to_string_lossy().to_string())
                .filter(|n| !n.starts_with('.') && !n.starts_with("_Laporan") && n != "_BCKUP Reports" && n != "$RECYCLE.BIN" && n != "System Volume Information")
                .collect()
        })
        .unwrap_or_default();
    v.sort_by(|a, b| crate::scanner::natural_cmp(a, b));
    v
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectInfo {
    pub rel: String,
    pub name: String,
    pub files: usize,
    pub bytes: u64,
    pub modified: Option<f64>,
    /// backup root → missing files (None = that backup was never read)
    pub missing: HashMap<String, Option<(usize, u64)>>,
}

pub fn projects(catalog: &Catalog, settings: &Settings, refresh: bool, progress: &dyn Fn(String)) -> Vec<ProjectInfo> {
    let Some(primary) = settings.primary_root.clone() else { return vec![] };
    if refresh && Path::new(&primary).is_dir() {
        progress("Reading the main folder…".into());
        let _ = catalog.refresh(&primary, None, |n| progress(format!("Reading the main folder… {n} files")));
        for b in &settings.backup_roots {
            if Path::new(b).is_dir() {
                progress(format!("Reading {}…", util::volume_label(b)));
                let _ = catalog.refresh(b, None, |_| {});
            }
        }
    }
    let mut projects: HashMap<String, ProjectInfo> = HashMap::new();
    let depth = if settings.use_client_folder { 2 } else { 1 };
    let root = Path::new(&primary);
    if settings.use_client_folder {
        for c in list_dirs(root) {
            for p in list_dirs(&root.join(&c)) {
                let rel = format!("{c}/{p}");
                projects.insert(rel.clone(), ProjectInfo { rel, name: p, files: 0, bytes: 0, modified: None, missing: HashMap::new() });
            }
        }
    } else {
        for p in list_dirs(root) {
            projects.insert(p.clone(), ProjectInfo { rel: p.clone(), name: p, files: 0, bytes: 0, modified: None, missing: HashMap::new() });
        }
    }
    let key = |rel: &str| -> Option<String> {
        let parts: Vec<&str> = rel.splitn(depth + 1, '/').collect();
        if parts.len() > depth { Some(parts[..depth].join("/")) } else { None }
    };
    let mut by_project: HashMap<String, Vec<crate::catalog::Entry>> = HashMap::new();
    for e in catalog.all(&primary).into_values() {
        if let Some(k) = key(&e.rel) {
            if projects.contains_key(&k) {
                by_project.entry(k).or_default().push(e);
            }
        }
    }
    let backups: Vec<(String, Option<HashMap<String, u64>>)> = settings
        .backup_roots
        .iter()
        .map(|b| {
            let all = catalog.all(b);
            if all.is_empty() && !Path::new(b).is_dir() {
                (b.clone(), None)
            } else {
                (b.clone(), Some(all.into_iter().map(|(k, v)| (k, v.size)).collect()))
            }
        })
        .collect();
    for (k, entries) in by_project {
        let p = projects.get_mut(&k).unwrap();
        p.files = entries.len();
        p.bytes = entries.iter().map(|e| e.size).sum();
        p.modified = entries.iter().map(|e| e.mtime).fold(None, |a: Option<f64>, b| Some(a.map_or(b, |x| x.max(b))));
        for (b, set) in &backups {
            match set {
                None => {
                    p.missing.insert(b.clone(), None);
                }
                Some(set) => {
                    let mut n = 0;
                    let mut bytes = 0;
                    for e in &entries {
                        if set.get(&e.rel) != Some(&e.size) {
                            n += 1;
                            bytes += e.size;
                        }
                    }
                    p.missing.insert(b.clone(), Some((n, bytes)));
                }
            }
        }
    }
    let mut v: Vec<ProjectInfo> = projects.into_values().collect();
    v.sort_by(|a, b| b.modified.unwrap_or(0.0).partial_cmp(&a.modified.unwrap_or(0.0)).unwrap_or(std::cmp::Ordering::Equal));
    v
}

pub fn project_options(settings: &Settings) -> Vec<String> {
    let Some(primary) = &settings.primary_root else { return vec![] };
    let root = Path::new(primary);
    let mut v: Vec<(String, f64)> = if settings.use_client_folder {
        list_dirs(root).into_iter().flat_map(|c| list_dirs(&root.join(&c)).into_iter().map(move |p| format!("{c}/{p}"))).map(|r| (r.clone(), 0.0)).collect()
    } else {
        list_dirs(root).into_iter().map(|r| (r, 0.0)).collect()
    };
    for (r, t) in v.iter_mut() {
        *t = std::fs::metadata(root.join(&*r)).map(|m| util::mtime_of(&m)).unwrap_or(0.0);
    }
    v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    v.into_iter().map(|x| x.0).collect()
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadItem {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub date: f64,
    pub is_folder: bool,
    pub kind: FileKind,
}

pub fn downloads(source: &str, days: u32) -> Vec<DownloadItem> {
    let dir = if let Ok(t) = std::env::var("BCKUP_TEST_DOWNLOADS") {
        Some(PathBuf::from(t))
    } else if source == "desktop" {
        dirs::desktop_dir()
    } else {
        dirs::download_dir()
    };
    let Some(dir) = dir else { return vec![] };
    let since = crate::scanner::now() - days as f64 * 86400.0;
    let partial = ["crdownload", "download", "part", "partial", "opdownload", "tmp"];
    let mut v: Vec<DownloadItem> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| {
                    let name = e.file_name().to_string_lossy().to_string();
                    if name.starts_with('.') || name.eq_ignore_ascii_case("desktop.ini") {
                        return None;
                    }
                    let p = e.path();
                    let ext = p.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
                    if partial.contains(&ext.as_str()) {
                        return None;
                    }
                    let meta = e.metadata().ok()?;
                    let date = meta
                        .created()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs_f64())
                        .unwrap_or_else(|| util::mtime_of(&meta))
                        .max(util::mtime_of(&meta));
                    if date < since {
                        return None;
                    }
                    Some(DownloadItem { path: p.to_string_lossy().to_string(), name, size: meta.len(), date, is_folder: meta.is_dir(), kind: crate::scanner::kind_of(&ext) })
                })
                .collect()
        })
        .unwrap_or_default();
    v.sort_by(|a, b| b.date.partial_cmp(&a.date).unwrap_or(std::cmp::Ordering::Equal));
    v
}

/// Copies items into Project/<subfolder>, verified. Originals go to the Recycle Bin only when asked.
pub fn copy_downloads(settings: &Settings, items: &[String], project: &str, subfolder: &str, move_originals: bool) -> Result<String, String> {
    let primary = settings.primary_root.clone().ok_or("Choose a main folder first")?;
    let sub = if util::clean_name(subfolder).is_empty() { "Assets".to_string() } else { util::clean_name(subfolder) };
    let dest = Path::new(&primary).join(project).join(&sub);
    let mut copied = vec![];
    let mut failed = vec![];
    for it in items {
        let p = PathBuf::from(it);
        let sources: Vec<(PathBuf, String)> = if p.is_dir() {
            let base = p.file_name().unwrap_or_default().to_string_lossy().to_string();
            crate::scanner::scan(&p, None).map(|s| s.files.into_iter().map(|f| (PathBuf::from(f.path), format!("{base}/{}", f.rel))).collect()).unwrap_or_default()
        } else {
            vec![(p.clone(), p.file_name().unwrap_or_default().to_string_lossy().to_string())]
        };
        let mut ok = true;
        for (src, rel) in sources {
            let target = dest.join(&rel);
            if target.exists() {
                if let (Ok(a), Ok(b)) = (util::hash_file(&src, None, |_| {}), util::hash_file(&target, None, |_| {})) {
                    if a == b {
                        continue;
                    }
                }
            }
            let mtime = std::fs::metadata(&src).map(|m| util::mtime_of(&m)).unwrap_or(0.0);
            match util::copy_verified(&src, &[target], mtime, &Cancel::new(), |_, _| {}) {
                Ok(r) if r.errors[0].is_none() => {}
                Ok(r) => {
                    ok = false;
                    failed.push(format!("{}: {}", src.display(), r.errors[0].clone().unwrap_or_default()))
                }
                Err(e) => {
                    ok = false;
                    failed.push(format!("{}: {e}", src.display()))
                }
            }
        }
        if ok {
            copied.push(p);
        }
    }
    if move_originals && !copied.is_empty() {
        let _ = trash::delete_all(&copied);
    }
    let mut m = format!("{} items copied & checked into {}/{}.", copied.len(), project, sub);
    if move_originals && !copied.is_empty() {
        m += " Originals moved to the Recycle Bin.";
    }
    if !failed.is_empty() {
        m += &format!(" Failed: {}", failed.into_iter().take(3).collect::<Vec<_>>().join("; "));
    }
    Ok(m)
}

/// Puts files on the clipboard as files (paste into WhatsApp, Explorer, email…).
pub fn copy_files_to_clipboard(paths: &[String]) -> Result<(), String> {
    #[cfg(windows)]
    {
        use clipboard_win::{formats, Clipboard, Setter};
        let _clip = Clipboard::new_attempts(10).map_err(|e| e.to_string())?;
        formats::FileList.write_clipboard(&paths.to_vec()).map_err(|e| e.to_string())
    }
    #[cfg(not(windows))]
    {
        let list = paths.iter().map(|p| format!("POSIX file \"{}\"", p.replace('"', "\\\""))).collect::<Vec<_>>().join(", ");
        let st = std::process::Command::new("osascript").args(["-e", &format!("set the clipboard to {{{list}}}")]).status().map_err(|e| e.to_string())?;
        if st.success() { Ok(()) } else { Err("Couldn't copy to the clipboard".into()) }
    }
}

pub fn drive_links(settings: &Settings, paths: &[String], spec: Option<CloudSpec>, progress: &dyn Fn(String)) -> Result<Vec<String>, String> {
    let spec = spec.ok_or("Google Drive isn't set up. Open Settings → Google Drive.")?;
    let root = settings.primary_root.clone().unwrap_or_default();
    let base = spec.target();
    let stamp = chrono::Local::now().format("%Y-%m-%d").to_string();
    let mut links = vec![];
    for (i, p) in paths.iter().enumerate() {
        let path = Path::new(p);
        let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
        let remote = match path.strip_prefix(&root) {
            Ok(rel) if !root.is_empty() => format!("{base}/{}", rel.to_string_lossy().replace('\\', "/")),
            _ => format!("{base}/_Shared/{stamp}/{name}"),
        };
        progress(format!("Uploading {} of {}: {name}", i + 1, paths.len()));
        let mut a = spec.extra_args.clone();
        a.extend([if path.is_dir() { "copy" } else { "copyto" }.to_string(), p.clone(), remote.clone()]);
        let up = cloud::run(&spec.rclone, &a, &Cancel::new(), |_| {});
        if up.status != 0 {
            return Err(format!("Upload failed: {}", up.last()));
        }
        progress(format!("Making link {} of {}…", i + 1, paths.len()));
        let mut l = spec.extra_args.clone();
        l.extend(["link".to_string(), remote]);
        let r = cloud::run(&spec.rclone, &l, &Cancel::new(), |_| {});
        let link = r.lines.iter().rev().find(|x| x.starts_with("http")).cloned();
        match (r.status, link) {
            (0, Some(link)) => links.push(if paths.len() > 1 { format!("{name}: {link}") } else { link }),
            _ => return Err(format!("Couldn't make the link: {}", r.last())),
        }
    }
    Ok(links)
}
