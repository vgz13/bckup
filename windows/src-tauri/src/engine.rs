//! Plan → copy & verify → optional Google Drive → reports. Same rules as the Mac app.

use crate::catalog::{Catalog, Entry};
use crate::cloud;
use crate::model::*;
use crate::scanner;
use crate::util::{self, Cancel, CANCELLED};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub fn plan(catalog: &Catalog, spec: &OffloadSpec, scan: &CardScan, cancel: &Cancel, progress: &dyn Fn(Progress)) -> Result<OffloadPlan, String> {
    let routed = scanner::route(&scan.files);
    let mut actions: HashMap<String, HashMap<String, DestAction>> = HashMap::new();
    let mut card_hashes: HashMap<String, String> = HashMap::new();
    let total = (scan.files.len() * spec.destinations.len().max(1)) as u64;
    let mut step = 0u64;

    for root in &spec.destinations {
        if !Path::new(root).is_dir() {
            return Err(format!("Destination not connected: {root}"));
        }
        let vol = util::volume_label(root);
        progress(Progress { phase: format!("Reading {vol}"), detail: root.clone(), ..Default::default() });
        catalog.refresh(root, Some(cancel), |n| progress(Progress { phase: format!("Reading {vol}"), detail: format!("{n} files found"), ..Default::default() }))?;
        let mut planned: HashSet<String> = HashSet::new();
        for f in &scan.files {
            if cancel.is_cancelled() {
                return Err(CANCELLED.into());
            }
            step += 1;
            let mut action = None;
            if spec.skip_existing {
                let cands = catalog.candidates(root, f.size);
                if !cands.is_empty() {
                    let fname = Path::new(&f.rel).file_name().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default();
                    let same_name = |e: &Entry| Path::new(&e.rel).file_name().map(|s| s.to_string_lossy().to_lowercase()).unwrap_or_default() == fname;
                    match spec.check_mode {
                        CheckMode::Fast => {
                            if let Some(c) = cands.iter().find(|c| same_name(c) && (c.mtime - f.mtime).abs() < 2.5) {
                                action = Some(DestAction::Skip { existing: c.rel.clone(), verified: false });
                            }
                        }
                        CheckMode::Thorough => {
                            progress(Progress { phase: format!("Comparing with {vol}"), detail: f.rel.clone(), done: step, total, ..Default::default() });
                            let ch = match card_hashes.get(&f.rel) {
                                Some(h) => h.clone(),
                                None => {
                                    let h = util::hash_file(Path::new(&f.path), Some(cancel), |_| {})?;
                                    card_hashes.insert(f.rel.clone(), h.clone());
                                    h
                                }
                            };
                            let mut ordered = cands.clone();
                            ordered.sort_by_key(|c| !same_name(c));
                            for c in ordered {
                                let h = match c.hash.clone() {
                                    Some(h) => h,
                                    None => {
                                        let p = Path::new(root).join(&c.rel);
                                        if !p.exists() {
                                            continue;
                                        }
                                        match util::hash_file(&p, Some(cancel), |_| {}) {
                                            Ok(h) => {
                                                catalog.set_hash(root, &c.rel, &h);
                                                h
                                            }
                                            Err(e) if e == CANCELLED => return Err(e),
                                            Err(_) => continue,
                                        }
                                    }
                                };
                                if h == ch {
                                    action = Some(DestAction::Skip { existing: c.rel.clone(), verified: true });
                                    break;
                                }
                            }
                        }
                    }
                }
            }
            let action = action.unwrap_or_else(|| {
                let (t, renamed) = unique_target(root, &spec.target_rel(f, *routed.get(&f.rel).unwrap_or(&FileKind::Video)), &mut planned);
                DestAction::Copy { target: t, renamed }
            });
            actions.entry(f.rel.clone()).or_default().insert(root.clone(), action);
            if step % 50 == 0 {
                progress(Progress { phase: format!("Checking {vol}"), detail: f.rel.clone(), done: step, total, ..Default::default() });
            }
        }
    }

    let items: Vec<PlanItem> = scan
        .files
        .iter()
        .map(|f| PlanItem {
            file: f.clone(),
            routed: *routed.get(&f.rel).unwrap_or(&FileKind::Video),
            actions: actions.remove(&f.rel).unwrap_or_default(),
            card_hash: card_hashes.get(&f.rel).cloned(),
        })
        .collect();
    let mut summaries: Vec<DestSummary> = spec
        .destinations
        .iter()
        .map(|r| {
            let sp = util::disk_space(r);
            DestSummary { root: r.clone(), name: util::volume_label(r), skip: 0, copy: 0, bytes: 0, renamed: 0, free: sp.map(|s| s.0), total: sp.map(|s| s.1) }
        })
        .collect();
    for it in &items {
        for s in summaries.iter_mut() {
            match it.actions.get(&s.root) {
                Some(DestAction::Skip { .. }) => s.skip += 1,
                Some(DestAction::Copy { renamed, .. }) => {
                    s.copy += 1;
                    s.bytes += it.file.size;
                    if *renamed {
                        s.renamed += 1;
                    }
                }
                None => {}
            }
        }
    }
    let files_to_copy = items.iter().filter(|i| i.needs_copy()).count();
    let bytes_to_copy = items.iter().filter(|i| i.needs_copy()).map(|i| i.file.size).sum();
    let renamed_count = items.iter().filter(|i| i.renamed()).count();
    let space_problem = summaries.iter().any(|s| s.free.map(|f| s.bytes > f).unwrap_or(false));
    Ok(OffloadPlan { spec: spec.clone(), items, summaries, files_to_copy, bytes_to_copy, renamed_count, space_problem })
}

fn unique_target(root: &str, rel: &str, planned: &mut HashSet<String>) -> (String, bool) {
    let taken = |r: &str, planned: &HashSet<String>| planned.contains(&r.to_lowercase()) || Path::new(root).join(r).exists();
    let mut cand = rel.to_string();
    let mut renamed = false;
    if taken(&cand, planned) {
        renamed = true;
        let (dir, name) = rel.rsplit_once('/').map(|(d, n)| (d.to_string(), n.to_string())).unwrap_or((String::new(), rel.to_string()));
        let (stem, ext) = name.rsplit_once('.').map(|(s, e)| (s.to_string(), Some(e.to_string()))).unwrap_or((name.clone(), None));
        let mut n = 2;
        loop {
            let nn = match &ext {
                Some(e) => format!("{stem}_{n}.{e}"),
                None => format!("{stem}_{n}"),
            };
            cand = if dir.is_empty() { nn } else { format!("{dir}/{nn}") };
            if !taken(&cand, planned) {
                break;
            }
            n += 1;
        }
    }
    planned.insert(cand.to_lowercase());
    (cand, renamed)
}

pub fn execute(catalog: &Catalog, plan: &OffloadPlan, cancel: &Cancel, progress: &dyn Fn(Progress)) -> OffloadResult {
    let spec = &plan.spec;
    let mut total = 0u64;
    for it in &plan.items {
        let n = it.actions.values().filter(|a| matches!(a, DestAction::Copy { .. })).count() as u64;
        if n > 0 {
            total += it.file.size * (1 + n);
        }
    }
    let mut done = 0u64;
    let mut results = vec![];
    let mut cancelled = false;
    let copy_count = plan.files_to_copy;
    let mut idx = 0;
    for it in &plan.items {
        let mut outcomes = HashMap::new();
        let mut hash = it.card_hash.clone();
        let mut targets: Vec<(String, String)> = vec![];
        for root in &spec.destinations {
            match it.actions.get(root) {
                Some(DestAction::Skip { existing, verified }) => {
                    outcomes.insert(root.clone(), DestOutcome::Existing { rel: existing.clone(), verified: *verified });
                }
                Some(DestAction::Copy { target, .. }) => targets.push((root.clone(), target.clone())),
                None => {}
            }
        }
        if !targets.is_empty() {
            if cancelled || cancel.is_cancelled() {
                cancelled = true;
                for (r, _) in &targets {
                    outcomes.insert(r.clone(), DestOutcome::Failed { message: "Cancelled".into() });
                }
            } else {
                idx += 1;
                let size_now = std::fs::metadata(&it.file.path).map(|m| m.len()).ok();
                if size_now != Some(it.file.size) {
                    for (r, _) in &targets {
                        outcomes.insert(r.clone(), DestOutcome::Failed { message: "The file on the card changed since it was checked".into() });
                    }
                } else {
                    let urls: Vec<PathBuf> = targets.iter().map(|(r, t)| Path::new(r).join(t)).collect();
                    let name = it.file.rel.clone();
                    let res = util::copy_verified(Path::new(&it.file.path), &urls, it.file.mtime, cancel, |n, phase| {
                        done += n;
                        progress(Progress {
                            phase: phase.into(),
                            detail: format!("File {idx} of {copy_count}: {name}"),
                            done,
                            total,
                            is_bytes: true,
                            file_index: idx,
                            file_count: copy_count,
                            file_name: name.clone(),
                        });
                    });
                    match res {
                        Ok(r) => {
                            if it.card_hash.as_ref().map(|h| h != &r.hash).unwrap_or(false) {
                                for (i, (root, _)) in targets.iter().enumerate() {
                                    if let Some(f) = &r.finals[i] {
                                        let _ = std::fs::remove_file(f);
                                    }
                                    outcomes.insert(root.clone(), DestOutcome::Failed { message: "The file's contents on the card changed since it was checked".into() });
                                }
                            } else {
                                hash = Some(r.hash.clone());
                                for (i, (root, _)) in targets.iter().enumerate() {
                                    if let Some(e) = &r.errors[i] {
                                        outcomes.insert(root.clone(), DestOutcome::Failed { message: e.clone() });
                                    } else if let Some(f) = &r.finals[i] {
                                        let rel = util::rel_path(f, Path::new(root));
                                        catalog.upsert(root, &Entry { rel: rel.clone(), size: it.file.size, mtime: it.file.mtime, hash: Some(r.hash.clone()) });
                                        outcomes.insert(root.clone(), DestOutcome::Copied { rel });
                                    }
                                }
                            }
                        }
                        Err(e) if e == CANCELLED => {
                            cancelled = true;
                            for (r, _) in &targets {
                                outcomes.insert(r.clone(), DestOutcome::Failed { message: "Cancelled".into() });
                            }
                        }
                        Err(e) => {
                            for (r, _) in &targets {
                                outcomes.insert(r.clone(), DestOutcome::Failed { message: e.clone() });
                            }
                        }
                    }
                }
            }
        }
        results.push(ItemResult { file: it.file.clone(), hash, outcomes });
    }
    OffloadResult {
        spec: spec.clone(),
        items: results,
        cancelled,
        cloud_ok: None,
        cloud_message: None,
        reports: vec![],
        started_at: 0,
        finished_at: 0,
        copied_count: 0,
        copied_bytes: 0,
        existing_count: 0,
        failures: 0,
        verdict: None,
    }
}

pub fn upload(result: &mut OffloadResult, cancel: &Cancel, progress: &(dyn Fn(Progress) + Sync)) {
    let Some(c) = result.spec.cloud.clone() else { return };
    let Some(primary) = result.spec.destinations.first().cloned() else { return };
    let rels: Vec<String> = result.items.iter().filter_map(|i| i.outcomes.get(&primary).and_then(|o| o.rel().map(String::from))).collect();
    if rels.is_empty() {
        return;
    }
    let list = std::env::temp_dir().join(format!("bckup-files-{}.txt", uuid::Uuid::new_v4()));
    if std::fs::write(&list, rels.join("\n")).is_err() {
        result.cloud_ok = Some(false);
        result.cloud_message = Some("Couldn't make the file list for Google Drive.".into());
        return;
    }
    let target = c.target();
    progress(Progress { phase: "Uploading to Google Drive".into(), detail: "Starting rclone…".into(), total: 100, ..Default::default() });
    let mut args = c.extra_args.clone();
    args.extend(
        ["copy", &primary, &target, "--files-from", &list.to_string_lossy(), "--transfers", "4", "--stats", "1s", "--stats-one-line", "--stats-log-level", "NOTICE", "--log-level", "NOTICE"]
            .map(String::from),
    );
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let up = std::thread::scope(|s| {
        let h = s.spawn(|| cloud::run(&c.rclone, &args, cancel, move |l| {
            let _ = tx.send(l.to_string());
        }));
        while !h.is_finished() {
            while let Ok(l) = rx.try_recv() {
                if let Some(p) = cloud::percent(&l) {
                    let detail = l.split("NOTICE:").last().unwrap_or(&l).trim().to_string();
                    progress(Progress { phase: "Uploading to Google Drive".into(), detail, done: p, total: 100, ..Default::default() });
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        h.join().unwrap()
    });
    if cancel.is_cancelled() {
        result.cloud_ok = Some(false);
        result.cloud_message = Some("Upload to Google Drive cancelled.".into());
        let _ = std::fs::remove_file(&list);
        return;
    }
    if up.status != 0 {
        result.cloud_ok = Some(false);
        result.cloud_message = Some(format!("Upload to Google Drive failed: {}", up.last()));
        let _ = std::fs::remove_file(&list);
        return;
    }
    progress(Progress { phase: "Checking MD5 on Google Drive".into(), detail: format!("{} files", rels.len()), ..Default::default() });
    let mut cargs = c.extra_args.clone();
    cargs.extend(["check", &primary, &target, "--files-from", &list.to_string_lossy(), "--one-way", "--log-level", "NOTICE"].map(String::from));
    let chk = cloud::run(&c.rclone, &cargs, cancel, |_| {});
    let _ = std::fs::remove_file(&list);
    if chk.status == 0 {
        result.cloud_ok = Some(true);
        result.cloud_message = Some(format!("{} files are on Google Drive and their MD5s match.", rels.len()));
    } else {
        result.cloud_ok = Some(false);
        result.cloud_message = Some(format!("Google Drive check didn't match: {}", chk.last()));
    }
}

pub fn write_reports(result: &OffloadResult, scan: &CardScan) -> Vec<String> {
    let spec = &result.spec;
    let stamp = chrono::Local::now().format("%Y-%m-%d %H.%M.%S").to_string();
    let base = format!("{} {}", if spec.roll.is_empty() { "Offload" } else { &spec.roll }, stamp);
    let csv = make_csv(result);
    let txt = make_text(result, scan);
    let mut out = vec![];
    for root in &spec.destinations {
        if !Path::new(root).is_dir() {
            continue;
        }
        let dir = Path::new(root).join(spec.project_rel()).join("_BCKUP Reports");
        if std::fs::create_dir_all(&dir).is_err() {
            continue;
        }
        let t = dir.join(format!("{base}.txt"));
        let c = dir.join(format!("{base}.csv"));
        if std::fs::write(&t, &txt).is_ok() && std::fs::write(&c, &csv).is_ok() {
            out.push(t.to_string_lossy().to_string());
            out.push(c.to_string_lossy().to_string());
        }
    }
    out
}

fn q(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\"\""))
}

fn make_csv(r: &OffloadResult) -> String {
    let dests = &r.spec.destinations;
    let mut header = vec!["file_on_card".to_string(), "size_bytes".into(), "xxh64".into(), "kind".into()];
    for (i, d) in dests.iter().enumerate() {
        header.push(format!("status_{} ({})", i + 1, util::volume_label(d)));
        header.push(format!("location_{}", i + 1));
    }
    if r.spec.cloud.is_some() {
        header.push("google_drive".into());
    }
    let mut lines = vec![header.iter().map(|h| q(h)).collect::<Vec<_>>().join(",")];
    for it in &r.items {
        let mut row = vec![it.file.rel.clone(), it.file.size.to_string(), it.hash.clone().unwrap_or_default(), format!("{:?}", it.file.kind)];
        for d in dests {
            let o = it.outcomes.get(d);
            row.push(o.map(|o| o.label()).unwrap_or_default());
            row.push(o.and_then(|o| o.rel().map(String::from)).unwrap_or_default());
        }
        if r.spec.cloud.is_some() {
            row.push(match r.cloud_ok {
                Some(true) => "Matches (MD5)".into(),
                Some(false) => "Failed".into(),
                None => String::new(),
            });
        }
        lines.push(row.iter().map(|c| q(c)).collect::<Vec<_>>().join(","));
    }
    lines.join("\n") + "\n"
}

fn make_text(r: &OffloadResult, scan: &CardScan) -> String {
    let fmt = |t: i64| chrono::DateTime::from_timestamp(t, 0).map(|d| d.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M:%S").to_string()).unwrap_or_default();
    let mut s = String::from("BCKUP OFFLOAD REPORT\n====================\n\n");
    s += &format!("Card       : {}\n", scan.name);
    s += &format!("Camera     : {}{}\n", scan.camera, scan.model.as_ref().map(|m| format!(" ({m})")).unwrap_or_default());
    s += &format!("Project    : {}\n", r.spec.project_rel());
    s += &format!("Roll       : {}\n", r.spec.roll);
    s += &format!("Started    : {}\n", fmt(r.started_at));
    s += &format!("Finished   : {}\n", fmt(r.finished_at));
    s += "Hash       : xxHash64 (XXH64), read back from the destination disk\n\nDestinations:\n";
    for (i, d) in r.spec.destinations.iter().enumerate() {
        let ok = r.items.iter().filter(|it| it.outcomes.get(d).map(|o| o.is_present()).unwrap_or(false)).count();
        s += &format!("  {} {}  —  {}/{} files present\n", if i == 0 { "Main  " } else { "Backup" }, d, ok, r.items.len());
    }
    if let Some(c) = &r.spec.cloud {
        s += &format!("  Cloud  {}  —  {}\n", c.target(), r.cloud_message.clone().unwrap_or("-".into()));
    }
    s += &format!("\nFiles        : {} ({})\n", r.items.len(), util::byte_text(scan.total_bytes));
    s += &format!("Copied       : {} ({})\n", r.copied_count, util::byte_text(r.copied_bytes));
    s += &format!("Already there: {}\n", r.existing_count);
    s += &format!("Failed       : {}\n\n", r.failures);
    if let Some(v) = &r.verdict {
        s += &format!("STATUS: {}\n{}\n", v.title.to_uppercase(), v.detail);
    }
    let failed: Vec<&ItemResult> = r.items.iter().filter(|i| i.outcomes.values().any(|o| matches!(o, DestOutcome::Failed { .. }))).collect();
    if !failed.is_empty() {
        s += "\nFailed files:\n";
        for f in failed {
            let msgs: HashSet<String> = f.outcomes.values().filter_map(|o| if let DestOutcome::Failed { message } = o { Some(message.clone()) } else { None }).collect();
            s += &format!("  {}: {}\n", f.file.rel, msgs.into_iter().collect::<Vec<_>>().join("; "));
        }
    }
    s
}
