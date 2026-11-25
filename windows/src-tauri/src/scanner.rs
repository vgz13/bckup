//! Reading cards: file kinds, camera detection, and where each file belongs (Video / Photo / Audio).

use crate::catalog::is_hidden;
use crate::model::{CardFile, CardScan, FileKind};
use crate::util::{self, Cancel, CANCELLED};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

const VIDEO: &[&str] = &[
    "mp4", "mov", "mxf", "braw", "r3d", "ari", "arx", "mts", "m2ts", "m2t", "avi", "crm", "insv", "mkv", "m4v", "mpg", "mpeg", "3gp", "wmv",
    "cine", "nev", "vrw", "dv", "hevc", "h264", "h265", "webm", "mod", "tod", "vob", "360", "ts",
];
const PHOTO: &[&str] = &[
    "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff", "dng", "arw", "srf", "sr2", "cr2", "cr3", "crw", "nef", "nrw", "raf", "rw2", "rwl",
    "orf", "ori", "pef", "srw", "x3f", "gpr", "3fr", "fff", "iiq", "erf", "kdc", "mef", "mos", "raw", "insp", "jxl", "avif", "webp", "bmp", "psd",
    "dcr", "mrw",
];
const AUDIO: &[&str] = &["wav", "bwf", "mp3", "m4a", "aac", "aif", "aiff", "flac", "ogg", "wma", "rf64", "w64", "caf"];
const SIDECAR: &[&str] = &[
    "xml", "xmp", "thm", "lrv", "lrf", "srt", "bim", "cpi", "mpl", "bdm", "smi", "ppn", "sav", "rdc", "rmd", "rtn", "ale", "cdl", "cube", "mhl", "txt",
    "log", "csv", "json", "dat", "cfg", "ind", "idx", "mif", "bin", "glv", "obs", "gyro", "ipl", "mhd",
];

const SKIP: &[&str] = &[".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", "System Volume Information", "$RECYCLE.BIN", "_BCKUP Reports", "_Laporan BCKUP", "_Laporan Amanin"];

const CARD_ROOTS: &[&str] = &[
    "DCIM", "PRIVATE", "CONTENTS", "XDROOT", "AVCHD", "CLIPS001", "M4ROOT", "DJI", "CAMERA01", "NIKON", "MISC", "AVF_INFO", "BLACKMAGIC", "FOLDER01",
    "ZOOM", "TASCAM", "MP_ROOT", "HDV", "SONY", "BPAV", "CLIP", "STREAM", "PANA_GRP", "INSTA360", "GOPRO", "EOS_DIGITAL", "CANONMSC", "AVCHDTN",
];

pub fn kind_of(ext: &str) -> FileKind {
    let e = ext.to_lowercase();
    let e = e.as_str();
    if VIDEO.contains(&e) {
        FileKind::Video
    } else if PHOTO.contains(&e) {
        FileKind::Photo
    } else if AUDIO.contains(&e) {
        FileKind::Audio
    } else if SIDECAR.contains(&e) {
        FileKind::Sidecar
    } else {
        FileKind::Other
    }
}

fn ext(p: &Path) -> String {
    p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

/// Cheap look at the top of a volume: does it look like a camera or recorder card?
pub fn looks_like_card(root: &Path) -> bool {
    let Ok(rd) = std::fs::read_dir(root) else { return false };
    let names: Vec<String> = rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect();
    let upper: Vec<String> = names.iter().map(|n| n.to_uppercase()).collect();
    if upper.iter().any(|n| ["WINDOWS", "PROGRAM FILES", "USERS", "LIBRARY", "APPLICATIONS", "SYSTEM"].contains(&n.as_str())) {
        return false;
    }
    if upper.iter().any(|n| CARD_ROOTS.contains(&n.as_str())) {
        return true;
    }
    let media = names
        .iter()
        .filter(|n| !n.starts_with('.'))
        .filter(|n| ["braw", "r3d", "rdm", "rdc", "mxf", "ari", "arx", "wav", "crm", "insv", "mov", "mp4"].contains(&ext(Path::new(n)).as_str()))
        .count();
    media > 0 && names.len() < 2000
}

fn card_file(p: &Path, root: &Path) -> Option<CardFile> {
    let name = p.file_name()?.to_string_lossy().to_string();
    if name.starts_with('.') || name.ends_with(".bckup-part") || name.ends_with(".amanin-part") {
        return None;
    }
    let meta = std::fs::metadata(p).ok()?;
    if !meta.is_file() {
        return None;
    }
    Some(CardFile {
        path: p.to_string_lossy().to_string(),
        rel: util::rel_path(p, root),
        size: meta.len(),
        mtime: util::mtime_of(&meta),
        kind: kind_of(&ext(p)),
    })
}

fn collect(dir: &Path, root: &Path, out: &mut Vec<CardFile>, cancel: Option<&Cancel>) -> Result<(), String> {
    for e in WalkDir::new(dir).into_iter().filter_entry(|e| {
        let n = e.file_name().to_string_lossy();
        e.depth() == 0 || (!SKIP.contains(&n.as_ref()) && !is_hidden(e.file_name()))
    }) {
        if cancel.map(|c| c.is_cancelled()).unwrap_or(false) {
            return Err(CANCELLED.into());
        }
        let Ok(e) = e else { continue };
        if e.file_type().is_file() {
            if let Some(f) = card_file(e.path(), root) {
                out.push(f);
            }
        }
    }
    Ok(())
}

pub fn scan(root: &Path, cancel: Option<&Cancel>) -> Result<CardScan, String> {
    if !root.exists() {
        return Err(format!("Couldn't read {}", root.display()));
    }
    let mut files = vec![];
    collect(root, root, &mut files, cancel)?;
    let is_volume = crate::util::volume_root(&root.to_string_lossy()).trim_end_matches(['\\', '/']) == root.to_string_lossy().trim_end_matches(['\\', '/']);
    let name = if is_volume { util::volume_label(&root.to_string_lossy()) } else { root.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default() };
    Ok(finish(root, name, files, None))
}

/// A loose set of dropped files and folders, kept relative to their common parent.
pub fn scan_items(items: &[PathBuf], name: &str, cancel: Option<&Cancel>) -> Result<CardScan, String> {
    let parents: Vec<Vec<_>> = items.iter().map(|p| p.parent().unwrap_or(Path::new("/")).components().collect()).collect();
    let mut common = parents.first().cloned().unwrap_or_default();
    for p in parents.iter().skip(1) {
        let n = common.iter().zip(p.iter()).take_while(|(a, b)| a == b).count();
        common.truncate(n);
    }
    let root: PathBuf = common.iter().collect();
    let mut files = vec![];
    for it in items {
        if it.is_dir() {
            collect(it, &root, &mut files, cancel)?;
        } else if let Some(f) = card_file(it, &root) {
            files.push(f);
        }
    }
    let mut seen = std::collections::HashSet::new();
    files.retain(|f| seen.insert(f.rel.clone()));
    Ok(finish(&root, name.to_string(), files, Some("Dropped files".into())))
}

fn finish(root: &Path, name: String, mut files: Vec<CardFile>, camera: Option<String>) -> CardScan {
    files.sort_by(|a, b| natural_cmp(&a.rel, &b.rel));
    let mut counts: HashMap<String, usize> = HashMap::new();
    for f in &files {
        *counts.entry(format!("{:?}", f.kind).to_lowercase()).or_default() += 1;
    }
    let dates: Vec<f64> = files.iter().filter(|f| f.kind.is_media() && f.mtime > 0.0).map(|f| f.mtime).collect();
    let mut per_day: HashMap<i64, (usize, f64)> = HashMap::new();
    for d in &dates {
        let day = (*d as i64 + local_offset()) / 86400;
        let e = per_day.entry(day).or_insert((0, *d));
        e.0 += 1;
    }
    let suggested = per_day.values().max_by_key(|v| v.0).map(|v| v.1).unwrap_or_else(now);
    CardScan {
        root: root.to_string_lossy().to_string(),
        name,
        camera: camera.unwrap_or_else(|| detect(&files)),
        model: model(&files),
        total_bytes: files.iter().map(|f| f.size).sum(),
        counts,
        suggested_date: suggested,
        first_date: dates.iter().cloned().fold(None, |a: Option<f64>, b| Some(a.map_or(b, |x| x.min(b)))),
        last_date: dates.iter().cloned().fold(None, |a: Option<f64>, b| Some(a.map_or(b, |x| x.max(b)))),
        files,
    }
}

fn local_offset() -> i64 {
    chrono::Local::now().offset().local_minus_utc() as i64
}

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Sorts "C0002" before "C0010" the way Finder and Explorer do.
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let (mut ai, mut bi) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (ai.peek().cloned(), bi.peek().cloned()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let mut na = String::new();
                while let Some(c) = ai.peek().cloned().filter(|c| c.is_ascii_digit()) {
                    na.push(c);
                    ai.next();
                }
                let mut nb = String::new();
                while let Some(c) = bi.peek().cloned().filter(|c| c.is_ascii_digit()) {
                    nb.push(c);
                    bi.next();
                }
                let o = na.parse::<u128>().unwrap_or(0).cmp(&nb.parse::<u128>().unwrap_or(0));
                if o != std::cmp::Ordering::Equal {
                    return o;
                }
            }
            (Some(x), Some(y)) => {
                let o = x.to_ascii_lowercase().cmp(&y.to_ascii_lowercase());
                if o != std::cmp::Ordering::Equal {
                    return o;
                }
                ai.next();
                bi.next();
            }
        }
    }
}

pub fn detect(files: &[CardFile]) -> String {
    if files.is_empty() {
        return "Empty card".into();
    }
    let rels: Vec<String> = files.iter().map(|f| f.rel.to_uppercase()).collect();
    let mut exts: HashMap<String, usize> = HashMap::new();
    for f in files {
        *exts.entry(ext(Path::new(&f.rel))).or_default() += 1;
    }
    let has = |e: &[&str]| e.iter().any(|x| exts.contains_key(*x));
    let path = |s: &str| rels.iter().any(|r| r.contains(s));
    let name = |p: &str| files.iter().any(|f| Path::new(&f.rel).file_name().map(|n| n.to_string_lossy().to_uppercase().starts_with(p)).unwrap_or(false));

    let checks: Vec<(bool, &str)> = vec![
        (path("M4ROOT/"), "Sony (XAVC)"),
        (path("XDROOT/") || path("BPAV/"), "Sony XDCAM"),
        (has(&["crm"]), "Canon Cinema RAW Light"),
        (path("CONTENTS/CLIPS"), "Canon Cinema EOS"),
        (has(&["braw"]), "Blackmagic (BRAW)"),
        (has(&["r3d"]), "RED"),
        (has(&["ari", "arx"]), "ARRI"),
        (has(&["insv", "insp"]) || path("INSTA360"), "Insta360"),
        (name("DJI_") || path("/DJI") || path("DJI_") || has(&["lrf"]), "DJI"),
        (path("GOPRO") || has(&["gpr"]) || name("GOPR") || name("GX0") || name("GH0"), "GoPro"),
        (path("PANA_GRP") || path("_PANA") || has(&["rw2"]), "Panasonic"),
        (has(&["arw", "srf", "sr2"]) || path("MSDCF"), "Sony"),
        (has(&["cr2", "cr3", "crw"]) || path("CANON") || path("EOSMISC"), "Canon"),
        (has(&["nef", "nrw", "nev"]) || path("NIKON") || path("NCFL"), "Nikon"),
        (has(&["raf"]) || path("_FUJI"), "Fujifilm"),
        (has(&["orf", "ori"]) || path("OLYMP") || path("OMSYS"), "OM System / Olympus"),
        (has(&["pef"]) || path("PENTX"), "Pentax / Ricoh"),
        (has(&["3fr", "fff"]), "Hasselblad"),
        (has(&["x3f"]) || path("SIGMA"), "Sigma"),
        (path("LEICA") || has(&["rwl"]), "Leica"),
        (has(&["iiq"]), "Phase One"),
        (path("AVCHD"), "AVCHD camera"),
        (name("ZOOM") || path("ZOOM"), "Zoom (audio recorder)"),
        (path("TASCAM") || name("TASCAM"), "Tascam (audio recorder)"),
        (has(&["mxf"]), "Broadcast camera (MXF)"),
    ];
    if let Some((_, n)) = checks.into_iter().find(|(c, _)| *c) {
        return n.into();
    }
    let (mut v, mut p, mut a) = (0, 0, 0);
    for f in files {
        match f.kind {
            FileKind::Video => v += 1,
            FileKind::Photo => p += 1,
            FileKind::Audio => a += 1,
            _ => {}
        }
    }
    if a > v && a > p {
        "Audio recorder".into()
    } else if v >= p && v > 0 {
        "Video camera".into()
    } else if p > 0 {
        "Photo camera".into()
    } else {
        "Unknown".into()
    }
}

/// Make and model from the EXIF of the first readable photo.
pub fn model(files: &[CardFile]) -> Option<String> {
    let exts = ["jpg", "jpeg", "arw", "cr3", "cr2", "nef", "raf", "rw2", "orf", "dng", "heic", "hif", "pef", "srw"];
    for f in files.iter().filter(|f| exts.contains(&ext(Path::new(&f.rel)).as_str())).take(4) {
        let Ok(file) = std::fs::File::open(&f.path) else { continue };
        let mut r = std::io::BufReader::new(file);
        let Ok(ex) = exif::Reader::new().read_from_container(&mut r) else { continue };
        let get = |t| ex.get_field(t, exif::In::PRIMARY).map(|f| f.display_value().to_string().trim_matches('"').trim().to_string());
        let make = get(exif::Tag::Make);
        let Some(model) = get(exif::Tag::Model).filter(|m| !m.is_empty()) else { continue };
        if let Some(make) = make.filter(|m| !m.is_empty()) {
            let first = make.split(' ').next().unwrap_or("").to_lowercase();
            if !model.to_lowercase().starts_with(&first) {
                return Some(format!("{make} {model}"));
            }
        }
        return Some(model);
    }
    None
}

const VIDEO_STRUCTURE: &[&str] = &["M4ROOT", "XDROOT", "CONTENTS", "AVCHD", "BDMV", "PANA_GRP", "CLIPS001", "XAVC", "BPAV"];

/// Decides whether each file goes to Video, Photo or Audio. Camera clip structures stay together,
/// sidecars follow the clip they belong to.
pub fn route(files: &[CardFile]) -> HashMap<String, FileKind> {
    let mut by_dir: HashMap<String, Vec<&CardFile>> = HashMap::new();
    for f in files {
        let dir = f.rel.rsplit_once('/').map(|x| x.0.to_string()).unwrap_or_default();
        by_dir.entry(dir).or_default().push(f);
    }
    let card_major = majority(files.iter()).unwrap_or(FileKind::Video);
    let mut out = HashMap::new();
    for f in files {
        let upper = f.rel.to_uppercase();
        let comps: Vec<&str> = upper.split('/').collect();
        let dirs = &comps[..comps.len().saturating_sub(1)];
        if dirs.iter().any(|c| VIDEO_STRUCTURE.contains(c) || c.ends_with(".RDC") || c.ends_with(".RDM")) {
            out.insert(f.rel.clone(), FileKind::Video);
            continue;
        }
        if f.kind.is_media() {
            out.insert(f.rel.clone(), f.kind);
            continue;
        }
        let dir = f.rel.rsplit_once('/').map(|x| x.0.to_string()).unwrap_or_default();
        let sib = by_dir.get(&dir).cloned().unwrap_or_default();
        let stem = |p: &str| Path::new(p).file_stem().map(|s| s.to_string_lossy().to_uppercase()).unwrap_or_default();
        let my = stem(&f.rel);
        let partner = sib.iter().find(|s| {
            let ss = stem(&s.rel);
            s.kind.is_media() && !ss.is_empty() && !my.is_empty() && (my.starts_with(&ss) || ss.starts_with(&my))
        });
        let k = partner.map(|p| p.kind).or_else(|| majority(sib.iter().copied())).unwrap_or(card_major);
        out.insert(f.rel.clone(), k);
    }
    out
}

fn majority<'a>(files: impl Iterator<Item = &'a CardFile>) -> Option<FileKind> {
    let mut c: HashMap<FileKind, usize> = HashMap::new();
    for f in files.filter(|f| f.kind.is_media()) {
        *c.entry(f.kind).or_default() += 1;
    }
    c.into_iter().max_by_key(|x| x.1).map(|x| x.0)
}
