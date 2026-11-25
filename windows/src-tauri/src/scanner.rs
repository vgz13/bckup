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

/// The card's camera: EXIF of the first photo, else the metadata of the first clips.
pub fn model(files: &[CardFile]) -> Option<String> {
    if let Some(m) = photo_model(files) {
        return Some(m);
    }
    files.iter().filter(|f| f.kind == FileKind::Video).take(3).find_map(|f| device_for(Path::new(&f.path)))
}

/// Make and model from the EXIF of the first readable photo.
fn photo_model(files: &[CardFile]) -> Option<String> {
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


// MARK: - Assets: category, sidecar partner, device

const GRAPHICS: &[&str] = &["png", "svg", "ai", "eps", "psd", "psb", "gif", "webp", "ico", "cdr", "sketch", "fig", "xd", "indd", "afdesign", "afphoto", "tga", "exr", "bmp"];
const DOCUMENTS: &[&str] = &["pdf", "doc", "docx", "ppt", "pptx", "key", "xls", "xlsx", "csv", "txt", "rtf", "pages", "numbers", "md", "odt", "ods", "odp", "srt", "vtt"];
const FONTS: &[&str] = &["ttf", "otf", "woff", "woff2", "ttc"];
const PROJECT_FILES: &[&str] = &["prproj", "aep", "aepx", "drp", "drt", "fcpxml", "fcpbundle", "edl", "aaf", "mogrt", "cube", "3dl", "lut", "veg", "xml", "blend", "c4d"];
const ARCHIVES: &[&str] = &["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "dmg", "iso"];

pub fn asset_category(p: &Path) -> &'static str {
    let e = ext(p);
    let e = e.as_str();
    if GRAPHICS.contains(&e) {
        return "graphics";
    }
    if DOCUMENTS.contains(&e) {
        return "documents";
    }
    if FONTS.contains(&e) {
        return "fonts";
    }
    if PROJECT_FILES.contains(&e) {
        return "projectFiles";
    }
    if ARCHIVES.contains(&e) {
        return "archives";
    }
    match kind_of(e) {
        FileKind::Video => "video",
        FileKind::Photo => "photo",
        FileKind::Audio => "audio",
        _ => "other",
    }
}

/// For a sidecar (C0001M01.XML, .THM, .SRT…), the clip or photo next to it whose name it starts with.
pub fn sidecar_partner(p: &Path) -> Option<std::path::PathBuf> {
    if kind_of(&ext(p)) != FileKind::Sidecar {
        return None;
    }
    let stem = p.file_stem()?.to_string_lossy().to_uppercase();
    let dir = p.parent()?;
    std::fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).find(|c| {
        let k = kind_of(&ext(c));
        let s = c.file_stem().map(|x| x.to_string_lossy().to_uppercase()).unwrap_or_default();
        (k == FileKind::Video || k == FileKind::Photo) && !s.is_empty() && stem.starts_with(&s)
    })
}

static DEVICES: std::sync::Mutex<Option<HashMap<String, Option<String>>>> = std::sync::Mutex::new(None);

/// A readable device name ("iPhone 15 Pro", "Sony ILCE-7M4", "Pixel", "DJI"…), or None.
pub fn device_for(p: &Path) -> Option<String> {
    let key = p.to_string_lossy().to_string();
    if let Some(hit) = DEVICES.lock().unwrap().get_or_insert_with(HashMap::new).get(&key) {
        return hit.clone();
    }
    let d = detect_device(p);
    DEVICES.lock().unwrap().get_or_insert_with(HashMap::new).insert(key, d.clone());
    d
}

fn detect_device(p: &Path) -> Option<String> {
    match kind_of(&ext(p)) {
        FileKind::Photo => {
            if let Some((make, model)) = exif_make_model(p) {
                return Some(pretty_device(make.as_deref(), &model));
            }
        }
        FileKind::Video => {
            if let Some((make, model)) = sony_xml(p).or_else(|| video_tags(p)) {
                return Some(pretty_device(make.as_deref(), &model));
            }
        }
        _ => {}
    }
    device_from_name(p)
}

fn exif_make_model(p: &Path) -> Option<(Option<String>, String)> {
    let file = std::fs::File::open(p).ok()?;
    let ex = exif::Reader::new().read_from_container(&mut std::io::BufReader::new(file)).ok()?;
    let get = |t| ex.get_field(t, exif::In::PRIMARY).map(|f| f.display_value().to_string().trim_matches('"').trim().to_string());
    let model = get(exif::Tag::Model).filter(|m| !m.is_empty())?;
    Some((get(exif::Tag::Make).filter(|m| !m.is_empty()), model))
}

/// Sony writes <Device manufacturer="Sony" modelName="ILCE-7M4"/> into C0001M01.XML next to each clip.
fn sony_xml(p: &Path) -> Option<(Option<String>, String)> {
    let stem = p.file_stem()?.to_string_lossy().to_string();
    for name in [format!("{stem}M01.XML"), format!("{stem}M01.xml")] {
        let Ok(text) = std::fs::read_to_string(p.with_file_name(name)) else { continue };
        let attr = |a: &str| -> Option<String> {
            let i = text.find(&format!("{a}=\""))? + a.len() + 2;
            let j = text[i..].find('"')? + i;
            Some(text[i..j].to_string())
        };
        if let Some(model) = attr("modelName").filter(|m| !m.is_empty()) {
            return Some((attr("manufacturer"), model));
        }
    }
    None
}

fn video_tags(p: &Path) -> Option<(Option<String>, String)> {
    let tags = mp4_tags(p);
    let find = |test: &dyn Fn(&str) -> bool| tags.iter().find(|(k, _)| test(&k.to_lowercase())).map(|(_, v)| v.trim().to_string()).filter(|v| !v.is_empty());
    let model = find(&|k| (k.contains("model") && !k.contains("modelname")) || k == "©mod");
    let make = find(&|k| k.contains("make") || k.contains("manufacturer") || k == "©mak");
    match (make, model) {
        (mk, Some(m)) => Some((mk, m)),
        (Some(mk), None) => Some((None, mk)),
        _ => None,
    }
}

fn device_from_name(p: &Path) -> Option<String> {
    let n = p.file_name()?.to_string_lossy().to_uppercase();
    if n.starts_with("DJI_") {
        return Some("DJI".into());
    }
    if n.starts_with("GX0") || n.starts_with("GH0") || n.starts_with("GOPR") || n.starts_with("GL0") {
        return Some("GoPro".into());
    }
    if n.starts_with("PXL_") {
        return Some("Pixel".into());
    }
    if n.starts_with("INSTA360") || n.ends_with(".INSV") || n.ends_with(".INSP") {
        return Some("Insta360".into());
    }
    None
}

pub fn pretty_device(make: Option<&str>, model: &str) -> String {
    let mut m = model.trim().to_string();
    let lower = make.unwrap_or("").trim().to_lowercase();
    let mut mk = make.unwrap_or("").trim().to_string();
    for (p, n) in [("sony", "Sony"), ("canon", "Canon"), ("nikon", "Nikon"), ("fujifilm", "Fujifilm"), ("panasonic", "Panasonic"), ("olympus", "OM System"), ("om digital", "OM System")] {
        if lower.starts_with(p) {
            mk = n.into();
        }
    }
    if lower == "apple" || lower == "google" || lower.starts_with("samsung") || lower.is_empty() {
        mk.clear();
    }
    if let Some(first) = mk.split(' ').next() {
        if !first.is_empty() && m.to_lowercase().starts_with(&first.to_lowercase()) {
            mk.clear();
        }
    }
    if m.to_lowercase().starts_with("sm-") {
        m = format!("Samsung {m}");
    }
    if mk.is_empty() { m } else { format!("{mk} {m}") }
}

/// Minimal reader for MP4 / MOV metadata (moov › udta / meta › keys + ilst, and ©xxx atoms).
pub fn mp4_tags(p: &Path) -> Vec<(String, String)> {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(p) else { return vec![] };
    let size = f.metadata().map(|m| m.len()).unwrap_or(0);
    let mut off = 0u64;
    while off + 8 <= size {
        let mut h = [0u8; 16];
        if f.seek(SeekFrom::Start(off)).is_err() || f.read(&mut h).unwrap_or(0) < 8 {
            break;
        }
        let mut bsize = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as u64;
        let mut hl = 8u64;
        if bsize == 1 {
            bsize = u64::from_be_bytes([h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]]);
            hl = 16;
        } else if bsize == 0 {
            bsize = size - off;
        }
        if bsize < hl {
            break;
        }
        if &h[4..8] == b"moov" {
            let len = (bsize - hl).min(64 << 20) as usize;
            let mut data = vec![0u8; len];
            if f.seek(SeekFrom::Start(off + hl)).is_err() || f.read_exact(&mut data).is_err() {
                return vec![];
            }
            let mut keys = vec![];
            let mut out = vec![];
            walk_boxes(&data, 0, data.len(), &mut keys, &mut out);
            return out;
        }
        off += bsize;
    }
    vec![]
}

fn be32(b: &[u8], i: usize) -> u32 {
    if i + 4 > b.len() { 0 } else { u32::from_be_bytes([b[i], b[i + 1], b[i + 2], b[i + 3]]) }
}

fn latin(b: &[u8]) -> String {
    let v: Vec<u8> = b.iter().copied().filter(|c| *c != 0).collect();
    String::from_utf8(v.clone()).unwrap_or_else(|_| v.iter().map(|c| *c as char).collect())
}

fn data_value(b: &[u8], start: usize, end: usize) -> Option<String> {
    let mut j = start;
    while j + 16 <= end {
        let s = be32(b, j) as usize;
        if s < 8 || j + s > end {
            return None;
        }
        if &b[j + 4..j + 8] == b"data" {
            return Some(latin(&b[j + 16..j + s]));
        }
        j += s;
    }
    None
}

fn walk_boxes(b: &[u8], start: usize, end: usize, keys: &mut Vec<String>, out: &mut Vec<(String, String)>) {
    let mut i = start;
    while i + 8 <= end {
        let size = be32(b, i) as usize;
        if size < 8 || i + size > end {
            break;
        }
        let typ = &b[i + 4..i + 8];
        let (body, stop) = (i + 8, i + size);
        match typ {
            b"meta" => {
                let skip = if be32(b, body) == 0 { 4 } else { 0 };
                walk_boxes(b, body + skip, stop, keys, out);
            }
            b"keys" => {
                let count = be32(b, body + 4) as usize;
                let mut j = body + 8;
                for _ in 0..count {
                    let ks = be32(b, j) as usize;
                    if ks < 8 || j + ks > stop {
                        break;
                    }
                    keys.push(latin(&b[j + 8..j + ks]));
                    j += ks;
                }
            }
            b"ilst" => {
                let mut j = body;
                while j + 8 <= stop {
                    let isz = be32(b, j) as usize;
                    if isz < 8 || j + isz > stop {
                        break;
                    }
                    let idx = be32(b, j + 4) as usize;
                    let name = if idx > 0 && idx <= keys.len() { keys[idx - 1].clone() } else { latin(&b[j + 4..j + 8]) };
                    if let Some(v) = data_value(b, j + 8, j + isz) {
                        out.push((name, v));
                    }
                    j += isz;
                }
            }
            b"moov" | b"udta" | b"trak" => walk_boxes(b, body, stop, keys, out),
            _ if typ[0] == 0xA9 => {
                let name = format!("©{}", latin(&typ[1..]));
                if let Some(v) = data_value(b, body, stop) {
                    out.push((name, v));
                } else if body + 4 <= stop {
                    let len = ((b[body] as usize) << 8) | b[body + 1] as usize;
                    out.push((name, latin(&b[body + 4..(body + 4 + len).min(stop)])));
                }
            }
            _ => {}
        }
        i = stop;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Settings;

    /// Run with BCKUP_TEST_ASSETS pointing at a folder of sample files (skipped otherwise).
    #[test]
    fn assets_go_to_material_by_type_and_device() {
        let Ok(dir) = std::env::var("BCKUP_TEST_ASSETS") else { return };
        let root = Path::new(&dir);
        let layout = Settings::default().asset_layout();
        let mut out = vec![];
        for e in walkdir::WalkDir::new(root).into_iter().flatten().filter(|e| e.file_type().is_file()) {
            let rel = crate::util::rel_path(e.path(), root);
            out.push(layout.rel(e.path(), &rel));
        }
        out.sort();
        for o in &out {
            println!("{o}");
        }
        let has = |s: &str| out.iter().any(|o| o == s);
        assert!(has("MATERIAL/Video/iPhone 15 Pro/IMG_4821.MOV"));
        assert!(has("MATERIAL/Video/Samsung SM-S918B/Client footage/VID_20261120_101500.mp4"));
        assert!(has("MATERIAL/Video/Sony ILCE-7M4/sony/C0007.MP4"));
        assert!(has("MATERIAL/Video/Sony ILCE-7M4/sony/C0007M01.XML"));
        assert!(has("MATERIAL/Video/DJI/DJI_0042.MP4"));
        assert!(has("MATERIAL/Photo/Fujifilm X-T5/DSCF1234.JPG"));
        assert!(has("MATERIAL/Graphics/logo-client.png"));
        assert!(has("MATERIAL/Documents/Brief.pdf"));
        assert!(has("MATERIAL/Fonts/Brand.otf"));
        assert!(has("MATERIAL/Archives/pack.zip"));
        assert!(has("MATERIAL/Audio/music.wav"));
        assert!(has("MATERIAL/Project Files/notes.prproj"));
    }
}
