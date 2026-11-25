mod catalog;
mod cloud;
mod drives;
mod engine;
mod library;
mod model;
mod scanner;
mod util;

use catalog::Catalog;
use model::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, State, WindowEvent};
use tauri_plugin_dialog::DialogExt;
use tauri_plugin_opener::OpenerExt;
use util::{Cancel, CANCELLED};

// MARK: - State

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobForm {
    pub client: String,
    pub project: String,
    pub date: f64,
    pub roll: String,
    pub backups_off: Vec<String>,
    pub use_cloud: bool,
    pub skip_existing: bool,
    pub check_mode: CheckMode,
    pub separate_by_type: bool,
    #[serde(default)]
    pub as_assets: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CardStatus {
    pub title: String,
    pub headline: String,
    pub detail: String,
    pub tone: String,
    pub safe: bool,
    pub missing: usize,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub source: String,
    pub name: String,
    pub items: Option<Vec<String>>,
    pub is_volume: bool,
    pub stage: String,
    pub error: Option<String>,
    pub scan: Option<CardScan>,
    pub plan: Option<OffloadPlan>,
    pub result: Option<OffloadResult>,
    pub progress: Progress,
    pub speed: f64,
    pub form: Option<JobForm>,
    pub quick: Option<OffloadPlan>,
    pub quick_running: bool,
    pub quick_verified: bool,
    #[serde(skip)]
    cancel: Cancel,
    #[serde(skip)]
    sample: Option<(std::time::Instant, u64)>,
}

impl Job {
    fn new(source: &str, name: &str, items: Option<Vec<String>>, is_volume: bool) -> Job {
        Job {
            source: source.into(),
            name: name.into(),
            items,
            is_volume,
            stage: "idle".into(),
            error: None,
            scan: None,
            plan: None,
            result: None,
            progress: Progress::default(),
            speed: 0.0,
            form: None,
            quick: None,
            quick_running: false,
            quick_verified: false,
            cancel: Cancel::new(),
            sample: None,
        }
    }

    fn busy(&self) -> bool {
        matches!(self.stage.as_str(), "scanning" | "planning" | "copying" | "uploading")
    }

    fn status_text(&self) -> String {
        match self.stage.as_str() {
            "idle" => "Not read yet".into(),
            "scanning" => "Reading the card…".into(),
            "ready" => "Ready to check".into(),
            "planning" => "Checking…".into(),
            "planned" => "Ready to copy".into(),
            "copying" => format!("Copying {}%", pct(&self.progress)),
            "uploading" => format!("Uploading {}%", pct(&self.progress)),
            "done" => self.result.as_ref().and_then(|r| r.verdict.as_ref()).map(|v| v.title.clone()).unwrap_or("Done".into()),
            _ => "Something went wrong".into(),
        }
    }

    fn card_status(&self) -> Option<CardStatus> {
        let st = |title: String, headline: String, detail: String, tone: &str, safe: bool, missing: usize| Some(CardStatus { title, headline, detail, tone: tone.into(), safe, missing });
        if self.stage == "copying" || self.stage == "uploading" {
            return st(format!("Copying {}%", pct(&self.progress)), "Copying now".into(), "Don't unplug the card until it's done.".into(), "accent", false, 0);
        }
        if self.stage == "done" {
            if let Some(r) = &self.result {
                let v = r.verdict.clone()?;
                let wh = r.spec.destinations.iter().map(|d| util::volume_label(d)).collect::<Vec<_>>().join(" and ");
                let tone = match v.kind.as_str() {
                    "safe" => "green",
                    "failed" => "red",
                    "oneCopy" | "unverified" => "orange",
                    _ => "gray",
                };
                return st(v.title, format!("On {wh}"), v.detail, tone, v.good, 0);
            }
        }
        let Some(p) = &self.quick else {
            if self.quick_running || self.stage == "scanning" {
                return st("Checking…".into(), "Comparing with your drives".into(), "Comparing the card with your drives.".into(), "gray", false, 0);
            }
            return None;
        };
        if p.items.is_empty() {
            return st("Empty card".into(), "No files".into(), "There are no files on this card.".into(), "gray", false, 0);
        }
        let full: Vec<String> = p.summaries.iter().filter(|s| s.copy == 0).map(|s| s.name.clone()).collect();
        let nowhere = p.items.iter().filter(|i| !i.actions.values().any(|a| matches!(a, DestAction::Skip { .. }))).count();
        let ft = full.join(" and ");
        if full.len() >= 2 && self.quick_verified {
            return st("Safe to format".into(), format!("All on {ft}"), format!("Every file on this card has a checked copy on {ft}."), "green", true, 0);
        }
        if full.len() >= 2 {
            return st("Looks backed up".into(), format!("All on {ft}"), format!("Every file was found on {ft} by name, size and date. Check the contents to be sure before formatting."), "orange", false, 0);
        }
        if full.len() == 1 {
            return st("Only 1 copy".into(), format!("All on {ft}"), format!("Every file is on {ft}. Keep a second copy before you format."), "orange", false, 0);
        }
        st(format!("{} files not copied yet", p.files_to_copy), format!("{nowhere} files aren't on any drive yet"), "Copy this card before you format it.".into(), "red", false, p.files_to_copy)
    }
}

fn pct(p: &Progress) -> u64 {
    if p.total > 0 { (p.done * 100 / p.total).min(100) } else { 0 }
}

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskState {
    pub running: bool,
    pub label: String,
    pub progress: Progress,
    pub message: Option<String>,
    pub links: Vec<String>,
    pub error: Option<String>,
}

#[derive(Clone, Serialize)]
pub struct Notice {
    pub id: String,
    pub text: String,
}

pub struct App {
    settings: Mutex<Settings>,
    catalog: Arc<Catalog>,
    jobs: Mutex<HashMap<String, Job>>,
    manual: Mutex<Vec<(String, String, Option<Vec<String>>)>>,
    volumes: Mutex<Vec<drives::Volume>>,
    notices: Mutex<Vec<Notice>>,
    backup_task: Mutex<TaskState>,
    share_task: Mutex<TaskState>,
    connect_task: Mutex<TaskState>,
    last_emit: AtomicU64,
}

type Shared = Arc<App>;

fn settings_path() -> PathBuf {
    util::data_dir().join("settings.json")
}

fn load_settings() -> Settings {
    std::fs::read_to_string(settings_path()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

fn save_settings_file(s: &Settings) {
    if let Ok(j) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(settings_path(), j);
    }
}

fn emit(app: &AppHandle) {
    let _ = app.emit("state", ());
}

/// Progress events are throttled so the UI isn't flooded.
fn emit_throttled(app: &AppHandle, st: &App) {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
    let last = st.last_emit.load(Ordering::Relaxed);
    if now.saturating_sub(last) >= 150 {
        st.last_emit.store(now, Ordering::Relaxed);
        emit(app);
    }
}

fn notify(app: &AppHandle, st: &App, text: String) {
    let mut n = st.notices.lock().unwrap();
    n.push(Notice { id: uuid::Uuid::new_v4().to_string(), text });
    if n.len() > 3 {
        n.remove(0);
    }
    drop(n);
    emit(app);
}

fn cloud_spec(s: &Settings) -> Option<CloudSpec> {
    let rc = cloud::find_rclone()?;
    match s.cloud_mode {
        CloudMode::OwnAccount => Some(CloudSpec { rclone: rc, remote: format!("{}:", cloud::OWN_REMOTE), path: s.cloud_path.clone(), extra_args: cloud::own_config_args() }),
        CloudMode::ExistingRemote => {
            if s.cloud_remote.is_empty() {
                None
            } else {
                Some(CloudSpec { rclone: rc, remote: s.cloud_remote.clone(), path: s.cloud_path.clone(), extra_args: vec![] })
            }
        }
    }
}

fn cloud_issue(s: &Settings) -> Option<String> {
    if cloud::find_rclone().is_none() {
        return Some("rclone isn't included in this app".into());
    }
    match s.cloud_mode {
        CloudMode::OwnAccount if !cloud::own_connected() => Some("Google account not connected (Settings → Google Drive)".into()),
        CloudMode::ExistingRemote if s.cloud_remote.is_empty() => Some("Choose a remote in Settings → Google Drive".into()),
        _ => None,
    }
}

fn cloud_display(s: &Settings) -> String {
    let p = s.cloud_path.trim_matches(|c| c == '/' || c == ' ');
    match s.cloud_mode {
        CloudMode::OwnAccount => if p.is_empty() { "Google Drive".into() } else { format!("Google Drive › {p}") },
        CloudMode::ExistingRemote => format!("{}{}", if s.cloud_remote.is_empty() { "remote:" } else { &s.cloud_remote }, p),
    }
}

// MARK: - Form → spec

fn date_text(s: &Settings, t: f64) -> String {
    chrono::DateTime::from_timestamp(t as i64, 0).map(|d| d.with_timezone(&chrono::Local).format(&s.date_format).to_string()).unwrap_or_default()
}

fn project_folder(s: &Settings, f: &JobForm) -> String {
    let name = util::clean_name(&f.project);
    if name.is_empty() {
        return String::new();
    }
    if let Some(p) = &s.primary_root {
        let base = if s.use_client_folder { Path::new(p).join(util::clean_name(&f.client)) } else { PathBuf::from(p) };
        if base.join(&name).is_dir() {
            return name;
        }
    }
    let d = date_text(s, f.date);
    match s.date_position {
        DatePosition::After => format!("{name} {d}"),
        DatePosition::Before => format!("{d} {name}"),
        DatePosition::None => name,
    }
}

fn active_destinations(s: &Settings, f: &JobForm) -> Vec<String> {
    let Some(p) = &s.primary_root else { return vec![] };
    if !Path::new(p).is_dir() {
        return vec![];
    }
    let mut v = vec![p.clone()];
    v.extend(s.backup_roots.iter().filter(|b| Path::new(b).is_dir() && !f.backups_off.contains(b)).cloned());
    v
}

fn make_spec(s: &Settings, f: &JobForm) -> OffloadSpec {
    OffloadSpec {
        client_folder: if s.use_client_folder { Some(util::clean_name(&f.client)) } else { None },
        project_folder: project_folder(s, f),
        roll: util::clean_name(&f.roll),
        destinations: active_destinations(s, f),
        separate_by_type: f.separate_by_type,
        video_folder: s.video_folder.clone(),
        photo_folder: s.photo_folder.clone(),
        audio_folder: s.audio_folder.clone(),
        skip_existing: f.skip_existing,
        check_mode: f.check_mode,
        cloud: if f.use_cloud && s.cloud_enabled { cloud_spec(s) } else { None },
        assets: if f.as_assets { Some(s.asset_layout()) } else { None },
        mirror_prefix: None,
    }
}

fn validation(s: &Settings, f: &JobForm) -> Option<String> {
    let Some(p) = &s.primary_root else { return Some("Choose a main folder first".into()) };
    if !Path::new(p).is_dir() {
        return Some("The main folder isn't connected. Plug in its drive first.".into());
    }
    if s.use_client_folder && util::clean_name(&f.client).is_empty() {
        return Some("Enter a client name".into());
    }
    if util::clean_name(&f.project).is_empty() {
        return Some("Enter a project name".into());
    }
    if !f.as_assets && util::clean_name(&f.roll).is_empty() {
        return Some("Enter a roll name".into());
    }
    if f.use_cloud && s.cloud_enabled {
        if let Some(i) = cloud_issue(s) {
            return Some(i);
        }
    }
    None
}

fn default_form(s: &Settings, scan: &CardScan, items: bool) -> JobForm {
    let brand = scan.camera.split([' ', '(', '/']).next().unwrap_or("Card").to_string();
    let generic = ["NO NAME", "UNTITLED", "EOS_DIGITAL", "CANON", "NIKON", "SONY", "LUMIX", "DJI", "GOPRO", "SD", "CARD", "INSTA360"];
    let card_name = scan.name.split(" (").next().unwrap_or(&scan.name).to_string();
    let roll = if items {
        "Extras".to_string()
    } else if generic.contains(&card_name.to_uppercase().as_str()) || card_name.is_empty() || card_name.starts_with("Local Disk") {
        let t = scan.first_date.unwrap_or_else(scanner::now) as i64;
        let hm = chrono::DateTime::from_timestamp(t, 0).map(|d| d.with_timezone(&chrono::Local).format("%H.%M").to_string()).unwrap_or_default();
        format!("{brand} {hm}")
    } else if card_name.to_uppercase().contains(&brand.to_uppercase()) {
        card_name
    } else {
        format!("{brand} {card_name}")
    };
    let recent = (chrono::Utc::now().timestamp() - s.last_used).abs() < 3 * 86400;
    JobForm {
        client: String::new(),
        project: if recent { s.last_project.clone() } else { String::new() },
        date: scan.suggested_date,
        roll: util::clean_name(&roll),
        backups_off: vec![],
        use_cloud: s.cloud_enabled,
        skip_existing: s.skip_existing,
        check_mode: s.check_mode,
        separate_by_type: s.separate_by_type,
        as_assets: items,
    }
}

// MARK: - Job work (threads)

fn with_job<R>(st: &App, source: &str, f: impl FnOnce(&mut Job) -> R) -> Option<R> {
    st.jobs.lock().unwrap().get_mut(source).map(f)
}

fn ensure_job(st: &App, source: &str) {
    let mut jobs = st.jobs.lock().unwrap();
    if jobs.contains_key(source) {
        return;
    }
    let vols = st.volumes.lock().unwrap();
    let manual = st.manual.lock().unwrap();
    let (name, items, is_volume) = if let Some(v) = vols.iter().find(|v| v.path == source) {
        (v.name.clone(), None, true)
    } else if let Some(m) = manual.iter().find(|m| m.0 == source) {
        (m.1.clone(), m.2.clone(), false)
    } else {
        (Path::new(source).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or(source.into()), None, false)
    };
    jobs.insert(source.to_string(), Job::new(source, &name, items, is_volume));
}

fn start_scan(app: AppHandle, st: Shared, source: String) {
    ensure_job(&st, &source);
    let (items, name) = match with_job(&st, &source, |j| {
        if j.busy() {
            return None;
        }
        j.stage = "scanning".into();
        j.scan = None;
        j.plan = None;
        j.result = None;
        j.quick = None;
        Some((j.items.clone(), j.name.clone()))
    }) {
        Some(Some(x)) => x,
        _ => return,
    };
    emit(&app);
    std::thread::spawn(move || {
        let res = match &items {
            Some(list) => scanner::scan_items(&list.iter().map(PathBuf::from).collect::<Vec<_>>(), &name, None),
            None => scanner::scan(Path::new(&source), None),
        };
        let settings = st.settings.lock().unwrap().clone();
        with_job(&st, &source, |j| match res {
            Ok(s) => {
                if j.form.is_none() {
                    j.form = Some(default_form(&settings, &s, j.items.is_some()));
                } else if let Some(f) = j.form.as_mut() {
                    f.date = s.suggested_date;
                }
                j.scan = Some(s);
                j.stage = "ready".into();
            }
            Err(e) => {
                j.stage = "error".into();
                j.error = Some(e);
            }
        });
        emit(&app);
        quick_check(app, st, source, false);
    });
}

fn quick_check(app: AppHandle, st: Shared, source: String, thorough: bool) {
    let settings = st.settings.lock().unwrap().clone();
    let prepared = with_job(&st, &source, |j| {
        if j.quick_running || j.busy() || j.scan.is_none() {
            return None;
        }
        let f = j.form.clone()?;
        let mut spec = make_spec(&settings, &f);
        if spec.destinations.is_empty() {
            return None;
        }
        if spec.project_folder.is_empty() {
            spec.project_folder = "_check".into();
        }
        if spec.roll.is_empty() {
            spec.roll = "_check".into();
        }
        spec.skip_existing = true;
        spec.check_mode = if thorough { CheckMode::Thorough } else { CheckMode::Fast };
        spec.cloud = None;
        j.quick_running = true;
        Some((spec, j.scan.clone().unwrap()))
    })
    .flatten();
    let Some((spec, scan)) = prepared else { return };
    emit(&app);
    std::thread::spawn(move || {
        let st2 = st.clone();
        let app2 = app.clone();
        let src2 = source.clone();
        let res = engine::plan(&st.catalog, &spec, &scan, &Cancel::new(), &move |p| {
            with_job(&st2, &src2, |j| j.progress = p);
            emit_throttled(&app2, &st2);
        });
        let name = with_job(&st, &source, |j| {
            j.quick_running = false;
            j.progress = Progress::default();
            if let Ok(p) = &res {
                j.quick = Some(p.clone());
                j.quick_verified = thorough;
            }
            j.name.clone()
        })
        .unwrap_or_default();
        if let Err(e) = res {
            if e != CANCELLED {
                notify(&app, &st, format!("{name}: {e}. Nothing was changed."));
            }
        }
        emit(&app);
    });
}

fn progress_sink(app: &AppHandle, st: &Shared, source: &str) -> impl Fn(Progress) + Send + Sync + 'static {
    let (app, st, source) = (app.clone(), st.clone(), source.to_string());
    move |p: Progress| {
        with_job(&st, &source, |j| {
            if p.is_bytes {
                let now = std::time::Instant::now();
                match j.sample {
                    Some((t, d)) if now.duration_since(t).as_secs_f64() >= 0.5 => {
                        let inst = (p.done.saturating_sub(d)) as f64 / now.duration_since(t).as_secs_f64();
                        j.speed = if j.speed == 0.0 { inst } else { j.speed * 0.7 + inst * 0.3 };
                        j.sample = Some((now, p.done));
                    }
                    None => j.sample = Some((now, p.done)),
                    _ => {}
                }
            }
            j.progress = p;
        });
        emit_throttled(&app, &st);
    }
}

// MARK: - Commands

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DestView {
    path: String,
    name: String,
    role: String,
    connected: bool,
    free: Option<u64>,
    total: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JobSummary {
    source: String,
    name: String,
    stage: String,
    status_text: String,
    card_status: Option<CardStatus>,
    percent: u64,
    preview: Option<String>,
    quick_running: bool,
    quick_verified: bool,
    has_matches: bool,
    is_volume: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SourceView {
    key: String,
    name: String,
    subtitle: String,
    kind: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StateView {
    platform: String,
    settings: Settings,
    cards: Vec<drives::Volume>,
    other_drives: Vec<drives::Volume>,
    sources: Vec<SourceView>,
    destinations: Vec<DestView>,
    plugged: Vec<(String, String)>,
    jobs: Vec<JobSummary>,
    notices: Vec<Notice>,
    cloud_issue: Option<String>,
    cloud_display: String,
    cloud_connected: bool,
    rclone: Option<String>,
    backup_task: TaskState,
    share_task: TaskState,
    connect_task: TaskState,
    busy_percent: Option<u64>,
    test_auto: bool,
    test_view: Option<String>,
}

fn role_of(s: &Settings, vol: &drives::Volume) -> String {
    let on = |root: &str| util::volume_root(root).trim_end_matches(['\\', '/']).eq_ignore_ascii_case(vol.path.trim_end_matches(['\\', '/']));
    if s.primary_root.as_deref().map(on).unwrap_or(false) {
        "Working drive".into()
    } else if s.backup_roots.iter().any(|b| on(b)) {
        "Backup drive".into()
    } else if vol.system {
        "System disk".into()
    } else {
        "Not used".into()
    }
}

#[tauri::command]
fn get_state(st: State<Shared>) -> StateView {
    let s = st.settings.lock().unwrap().clone();
    let vols = st.volumes.lock().unwrap().clone();
    let dest_vols: Vec<String> = s.primary_root.iter().chain(s.backup_roots.iter()).map(|r| util::volume_root(r).trim_end_matches(['\\', '/']).to_lowercase()).collect();
    let is_dest = |v: &drives::Volume| dest_vols.contains(&v.path.trim_end_matches(['\\', '/']).to_lowercase());
    let cards: Vec<drives::Volume> = vols.iter().filter(|v| v.is_card && !is_dest(v) && !s.hidden_volumes.contains(&v.id)).cloned().collect();
    let other: Vec<drives::Volume> = vols.iter().filter(|v| !v.is_card && !v.system && !is_dest(v) && !s.hidden_volumes.contains(&v.id)).cloned().collect();
    let plugged = vols.iter().filter(|v| !cards.contains(v) && !s.hidden_volumes.contains(&v.id)).map(|v| (v.name.clone(), role_of(&s, v))).collect();
    let mut destinations = vec![];
    if let Some(p) = &s.primary_root {
        let sp = util::disk_space(p);
        destinations.push(DestView { path: p.clone(), name: util::volume_label(p), role: "Main".into(), connected: Path::new(p).is_dir(), free: sp.map(|x| x.0), total: sp.map(|x| x.1) });
    }
    for b in &s.backup_roots {
        let sp = util::disk_space(b);
        destinations.push(DestView { path: b.clone(), name: util::volume_label(b), role: "Backup".into(), connected: Path::new(b).is_dir(), free: sp.map(|x| x.0), total: sp.map(|x| x.1) });
    }
    let sources = st
        .manual
        .lock()
        .unwrap()
        .iter()
        .map(|(k, n, items)| SourceView {
            key: k.clone(),
            name: n.clone(),
            subtitle: items.as_ref().and_then(|i| i.first()).map(|p| Path::new(p).parent().map(|x| x.display().to_string()).unwrap_or_default()).unwrap_or_else(|| k.clone()),
            kind: if items.is_some() { "drop".into() } else { "folder".into() },
        })
        .collect();
    let jobs: Vec<JobSummary> = st
        .jobs
        .lock()
        .unwrap()
        .values()
        .map(|j| JobSummary {
            source: j.source.clone(),
            name: j.name.clone(),
            stage: j.stage.clone(),
            status_text: j.status_text(),
            card_status: j.card_status(),
            percent: pct(&j.progress),
            preview: j.scan.as_ref().and_then(|s| {
                s.files.iter().find(|f| f.kind == FileKind::Photo && ["jpg", "jpeg", "png"].iter().any(|e| f.rel.to_lowercase().ends_with(e)) && !f.rel.to_uppercase().contains("THMBNL")).map(|f| f.path.clone())
            }),
            quick_running: j.quick_running,
            quick_verified: j.quick_verified,
            has_matches: j.quick.as_ref().map(|q| q.summaries.iter().any(|s| s.copy == 0)).unwrap_or(false),
            is_volume: j.is_volume,
        })
        .collect();
    let busy_percent = st.jobs.lock().unwrap().values().find(|j| j.stage == "copying" || j.stage == "uploading").map(|j| pct(&j.progress));
    StateView {
        platform: if cfg!(windows) { "windows".into() } else { "mac".into() },
        cloud_issue: cloud_issue(&s),
        cloud_display: cloud_display(&s),
        cloud_connected: cloud::own_connected(),
        rclone: cloud::find_rclone(),
        settings: s,
        cards,
        other_drives: other,
        sources,
        destinations,
        plugged,
        jobs,
        notices: st.notices.lock().unwrap().clone(),
        backup_task: st.backup_task.lock().unwrap().clone(),
        share_task: st.share_task.lock().unwrap().clone(),
        connect_task: st.connect_task.lock().unwrap().clone(),
        busy_percent,
        test_auto: std::env::var("BCKUP_TEST_AUTO").is_ok(),
        test_view: std::env::var("BCKUP_TEST_VIEW").ok(),
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JobDetail {
    job: Job,
    validation: Option<String>,
    project_folder: String,
    project_exists: bool,
    breadcrumb: Vec<(String, bool)>,
    preview_path: String,
    clients: Vec<String>,
    projects: Vec<String>,
    destinations: Vec<String>,
    copies: usize,
}

#[tauri::command]
fn get_job(st: State<Shared>, app: AppHandle, source: String) -> Option<JobDetail> {
    ensure_job(&st, &source);
    let needs_scan = with_job(&st, &source, |j| j.stage == "idle").unwrap_or(false);
    if needs_scan {
        start_scan(app.clone(), st.inner().clone(), source.clone());
    }
    let s = st.settings.lock().unwrap().clone();
    let job = st.jobs.lock().unwrap().get(&source).cloned()?;
    let form = job.form.clone();
    let (validation, project_folder, project_exists, breadcrumb, preview_path, destinations) = match &form {
        Some(f) => {
            let spec = make_spec(&s, f);
            let pf = spec.project_folder.clone();
            let base = s.primary_root.clone().unwrap_or_default();
            let exists = !pf.is_empty() && Path::new(&base).join(spec.project_rel()).is_dir() && util::clean_name(&f.project) == pf;
            let mut crumbs = vec![(Path::new(&base).file_name().map(|x| x.to_string_lossy().to_string()).unwrap_or(base.clone()), false)];
            let mut levels = vec![];
            if let Some(c) = &spec.client_folder {
                levels.push(if c.is_empty() { "Client".into() } else { c.clone() });
            }
            levels.push(if pf.is_empty() { "Project".into() } else { pf.clone() });
            if let Some(a) = &spec.assets {
                levels.push(a.folder.clone());
                if a.split {
                    if let Some(sc) = &job.scan {
                        let present: std::collections::HashSet<&str> = sc.files.iter().map(|f| scanner::asset_category(Path::new(&f.path))).collect();
                        let names: Vec<String> = ASSET_CATEGORIES.iter().filter(|(k, _)| present.contains(k)).map(|(k, d)| a.names.get(*k).cloned().unwrap_or(d.to_string())).collect();
                        if !names.is_empty() {
                            levels.push(if names.len() > 4 { format!("{} …", names[..4].join(" · ")) } else { names.join(" · ") });
                        }
                    }
                }
            } else if spec.separate_by_type {
                if let Some(sc) = &job.scan {
                    let r = scanner::route(&sc.files);
                    let kinds: Vec<String> = [FileKind::Video, FileKind::Photo, FileKind::Audio]
                        .iter()
                        .filter(|k| r.values().any(|v| v == *k))
                        .filter_map(|k| s.kind_folder(*k).map(String::from))
                        .collect();
                    if !kinds.is_empty() {
                        levels.push(kinds.join(" · "));
                    }
                }
            }
            if spec.assets.is_none() {
                levels.push(if spec.roll.is_empty() { "Roll".into() } else { spec.roll.clone() });
            }
            let mut path = PathBuf::from(&base);
            let mut missing = false;
            for l in levels {
                path = path.join(l.split(" · ").next().unwrap_or(&l));
                if !missing && !path.is_dir() {
                    missing = true;
                }
                crumbs.push((l, missing));
            }
            let sample = job.scan.as_ref().and_then(|sc| sc.files.iter().find(|f| f.kind == FileKind::Video).or(sc.files.first()));
            let preview = sample.map(|f| format!("{}/{}", base, spec.target_rel(f, scanner::route(std::slice::from_ref(f)).get(&f.rel).cloned().unwrap_or(FileKind::Video)))).unwrap_or_default();
            (validation(&s, f), pf, exists, crumbs, preview, spec.destinations.clone())
        }
        None => (Some("Reading the card…".into()), String::new(), false, vec![], String::new(), vec![]),
    };
    let root = s.primary_root.clone().map(PathBuf::from);
    let clients = root.as_ref().filter(|_| s.use_client_folder).map(|r| library::list_dirs(r)).unwrap_or_default();
    let projects = root
        .as_ref()
        .map(|r| {
            if s.use_client_folder {
                let c = form.as_ref().map(|f| util::clean_name(&f.client)).unwrap_or_default();
                if c.is_empty() { vec![] } else { library::list_dirs(&r.join(c)) }
            } else {
                library::list_dirs(r)
            }
        })
        .unwrap_or_default();
    let copies = destinations.len() + if form.as_ref().map(|f| f.use_cloud).unwrap_or(false) && s.cloud_enabled { 1 } else { 0 };
    Some(JobDetail { job, validation, project_folder, project_exists, breadcrumb, preview_path, clients, projects, destinations, copies })
}

#[tauri::command]
fn update_form(st: State<Shared>, source: String, form: JobForm) {
    with_job(&st, &source, |j| {
        j.form = Some(form);
        if j.stage == "planned" {
            j.plan = None;
            j.stage = "ready".into();
        }
    });
}

#[tauri::command]
fn rescan(st: State<Shared>, app: AppHandle, source: String) {
    start_scan(app, st.inner().clone(), source);
}

#[tauri::command]
fn check_job(st: State<Shared>, app: AppHandle, source: String) -> Result<(), String> {
    let s = st.settings.lock().unwrap().clone();
    let (spec, scan, cancel) = with_job(&st, &source, |j| -> Result<_, String> {
        let f = j.form.clone().ok_or("Reading the card…")?;
        if let Some(v) = validation(&s, &f) {
            return Err(v);
        }
        let scan = j.scan.clone().ok_or("Reading the card…")?;
        j.cancel = Cancel::new();
        j.stage = "planning".into();
        j.plan = None;
        j.result = None;
        j.progress = Progress { phase: "Starting…".into(), ..Default::default() };
        Ok((make_spec(&s, &f), scan, j.cancel.clone()))
    })
    .ok_or("No such card")??;
    emit(&app);
    let st = st.inner().clone();
    std::thread::spawn(move || {
        let sink = progress_sink(&app, &st, &source);
        let res = engine::plan(&st.catalog, &spec, &scan, &cancel, &sink);
        with_job(&st, &source, |j| match res {
            Ok(p) => {
                j.plan = Some(p);
                j.stage = "planned".into();
            }
            Err(e) if e == CANCELLED => j.stage = "ready".into(),
            Err(e) => {
                j.stage = "error".into();
                j.error = Some(e);
            }
        });
        emit(&app);
    });
    Ok(())
}

#[tauri::command]
fn start_job(st: State<Shared>, app: AppHandle, source: String) -> Result<(), String> {
    let (plan, scan, cancel, form) = with_job(&st, &source, |j| -> Result<_, String> {
        let plan = j.plan.clone().ok_or("Check the card first")?;
        j.cancel = Cancel::new();
        j.stage = "copying".into();
        j.speed = 0.0;
        j.sample = None;
        j.progress = Progress { phase: "Copying".into(), is_bytes: true, ..Default::default() };
        Ok((plan, j.scan.clone().unwrap(), j.cancel.clone(), j.form.clone()))
    })
    .ok_or("No such card")??;
    {
        let mut s = st.settings.lock().unwrap();
        if let Some(f) = &form {
            s.last_project = plan.spec.project_folder.clone();
            let _ = f;
            s.last_used = chrono::Utc::now().timestamp();
        }
        save_settings_file(&s);
    }
    emit(&app);
    let st = st.inner().clone();
    std::thread::spawn(move || {
        let started = chrono::Utc::now().timestamp();
        let sink = progress_sink(&app, &st, &source);
        let mut r = engine::execute(&st.catalog, &plan, &cancel, &sink);
        r.finish();
        if plan.spec.cloud.is_some() && !r.cancelled && r.failures == 0 {
            with_job(&st, &source, |j| {
                j.stage = "uploading".into();
                j.speed = 0.0;
                j.sample = None;
            });
            emit(&app);
            engine::upload(&mut r, &cancel, &sink);
        }
        r.started_at = started;
        r.finished_at = chrono::Utc::now().timestamp();
        r.finish();
        r.reports = engine::write_reports(&r, &scan);
        with_job(&st, &source, |j| {
            j.result = Some(r);
            j.stage = "done".into();
        });
        emit(&app);
    });
    Ok(())
}

#[tauri::command]
fn cancel_job(st: State<Shared>, source: String) {
    with_job(&st, &source, |j| j.cancel.cancel());
}

#[tauri::command]
fn reset_job(st: State<Shared>, app: AppHandle, source: String) {
    with_job(&st, &source, |j| {
        j.plan = None;
        j.result = None;
        j.error = None;
        j.stage = if j.scan.is_some() { "ready".into() } else { "idle".into() };
    });
    emit(&app);
}

#[tauri::command]
fn run_quick_check(st: State<Shared>, app: AppHandle, source: String, thorough: bool) {
    quick_check(app, st.inner().clone(), source, thorough);
}

fn refresh_in_background(app: &AppHandle, st: &Shared) {
    let (app, st) = (app.clone(), st.clone());
    std::thread::spawn(move || refresh_volumes(&app, &st, false));
}

#[tauri::command]
async fn eject(app: AppHandle, source: String) -> Result<(), String> {
    let src = source.clone();
    tauri::async_runtime::spawn_blocking(move || drives::eject(&src)).await.map_err(|e| e.to_string())??;
    let st = app.state::<Shared>().inner().clone();
    st.jobs.lock().unwrap().remove(&source);
    refresh_in_background(&app, &st);
    Ok(())
}

#[tauri::command]
fn save_settings(st: State<Shared>, app: AppHandle, settings: Settings) {
    *st.settings.lock().unwrap() = settings.clone();
    save_settings_file(&settings);
    refresh_in_background(&app, st.inner());
    emit(&app);
}

async fn pick(app: &AppHandle, title: &str) -> Option<String> {
    app.dialog().file().set_title(title).blocking_pick_folder().and_then(|p| p.into_path().ok()).map(|p| p.to_string_lossy().to_string())
}

#[tauri::command]
async fn choose_primary(app: AppHandle) -> Result<(), String> {
    let Some(p) = pick(&app, "Main footage folder").await else { return Ok(()) };
    let st = app.state::<Shared>();
    let mut s = st.settings.lock().unwrap().clone();
    s.backup_roots.retain(|b| b != &p);
    s.primary_root = Some(p);
    *st.settings.lock().unwrap() = s.clone();
    save_settings_file(&s);
    emit(&app);
    Ok(())
}

#[tauri::command]
async fn add_backup(app: AppHandle) -> Result<(), String> {
    let Some(p) = pick(&app, "Backup folder (on another drive)").await else { return Ok(()) };
    let st = app.state::<Shared>();
    let mut s = st.settings.lock().unwrap().clone();
    if s.primary_root.as_deref() != Some(p.as_str()) && !s.backup_roots.contains(&p) {
        s.backup_roots.push(p);
    }
    *st.settings.lock().unwrap() = s.clone();
    save_settings_file(&s);
    emit(&app);
    Ok(())
}

#[tauri::command]
async fn choose_source(app: AppHandle) -> Result<Option<String>, String> {
    let Some(p) = pick(&app, "Choose a card or source folder").await else { return Ok(None) };
    Ok(Some(add_sources(&app, vec![p])))
}

fn add_sources(app: &AppHandle, paths: Vec<String>) -> String {
    let st = app.state::<Shared>();
    let vols = st.volumes.lock().unwrap().clone();
    if paths.len() == 1 {
        let p = &paths[0];
        if let Some(v) = vols.iter().find(|v| v.path.trim_end_matches(['\\', '/']) == p.trim_end_matches(['\\', '/'])) {
            return v.path.clone();
        }
        if Path::new(p).is_dir() {
            let mut m = st.manual.lock().unwrap();
            if !m.iter().any(|x| &x.0 == p) {
                m.push((p.clone(), Path::new(p).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or(p.clone()), None));
            }
            drop(m);
            emit(app);
            return p.clone();
        }
    }
    let key = format!("drop:{}", uuid::Uuid::new_v4());
    let name = if paths.len() == 1 { Path::new(&paths[0]).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default() } else { format!("{} dropped items", paths.len()) };
    st.manual.lock().unwrap().push((key.clone(), name, Some(paths)));
    emit(app);
    key
}

#[tauri::command]
fn add_dropped(app: AppHandle, paths: Vec<String>) -> String {
    add_sources(&app, paths)
}

#[tauri::command]
fn remove_source(st: State<Shared>, app: AppHandle, key: String) {
    st.manual.lock().unwrap().retain(|m| m.0 != key);
    st.jobs.lock().unwrap().retain(|k, j| k != &key || j.busy());
    emit(&app);
}

#[tauri::command]
fn hide_volume(st: State<Shared>, app: AppHandle, id: String) {
    let mut s = st.settings.lock().unwrap();
    s.hidden_volumes.push(id);
    save_settings_file(&s);
    drop(s);
    emit(&app);
}

#[tauri::command]
fn dismiss_notice(st: State<Shared>, app: AppHandle, id: String) {
    st.notices.lock().unwrap().retain(|n| n.id != id);
    emit(&app);
}

#[tauri::command]
fn open_path(app: AppHandle, path: String) -> Result<(), String> {
    app.opener().open_path(path, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn reveal(app: AppHandle, path: String) -> Result<(), String> {
    app.opener().reveal_item_in_dir(path).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_side_by_side(st: State<Shared>, app: AppHandle, source: String) -> Result<(), String> {
    let s = st.settings.lock().unwrap().clone();
    let left = st.jobs.lock().unwrap().get(&source).and_then(|j| j.scan.as_ref().map(|s| s.root.clone())).unwrap_or(source.clone());
    let mut right = s.primary_root.clone().unwrap_or_default();
    if let Some(j) = st.jobs.lock().unwrap().get(&source) {
        let rel = j.result.as_ref().map(|r| r.spec.project_rel()).or_else(|| j.form.as_ref().map(|f| make_spec(&s, f).project_rel())).unwrap_or_default();
        let cand = Path::new(&right).join(&rel);
        if !rel.is_empty() && cand.is_dir() {
            right = cand.to_string_lossy().to_string();
        }
    }
    #[cfg(windows)]
    {
        // Two Explorer windows; Windows snaps them with Win+Left / Win+Right.
        let _ = std::process::Command::new("explorer").arg(&left).spawn();
        let _ = std::process::Command::new("explorer").arg(&right).spawn();
        let _ = app;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        app.opener().open_path(left, None::<&str>).map_err(|e| e.to_string())?;
        app.opener().open_path(right, None::<&str>).map_err(|e| e.to_string())
    }
}

#[tauri::command]
fn get_projects(st: State<Shared>, app: AppHandle, refresh: bool) -> Vec<library::ProjectInfo> {
    let s = st.settings.lock().unwrap().clone();
    let app2 = app.clone();
    let st2 = st.inner().clone();
    library::projects(&st.catalog, &s, refresh, &move |m| {
        let mut t = st2.backup_task.lock().unwrap();
        if !t.running {
            t.label = m;
        }
        drop(t);
        emit_throttled(&app2, &st2);
    })
}

#[tauri::command]
fn backup_project(st: State<Shared>, app: AppHandle, rel: String) -> Result<(), String> {
    let s = st.settings.lock().unwrap().clone();
    let primary = s.primary_root.clone().ok_or("Choose a main folder first")?;
    let backups: Vec<String> = s.backup_roots.iter().filter(|b| Path::new(b).is_dir()).cloned().collect();
    if backups.is_empty() {
        return Err("Plug in a backup drive first.".into());
    }
    {
        let mut t = st.backup_task.lock().unwrap();
        if t.running {
            return Err("A backup is already running".into());
        }
        *t = TaskState { running: true, label: rel.clone(), ..Default::default() };
    }
    emit(&app);
    let st = st.inner().clone();
    std::thread::spawn(move || {
        let folder = Path::new(&primary).join(&rel);
        let cancel = Cancel::new();
        let app2 = app.clone();
        let st2 = st.clone();
        let sink = move |p: Progress| {
            st2.backup_task.lock().unwrap().progress = p;
            emit_throttled(&app2, &st2);
        };
        let name = Path::new(&rel).file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or(rel.clone());
        let msg = (|| -> Result<String, String> {
            let scan = scanner::scan(&folder, Some(&cancel))?;
            let spec = OffloadSpec {
                client_folder: None,
                project_folder: rel.clone(),
                roll: "Project backup".into(),
                destinations: backups,
                separate_by_type: false,
                video_folder: String::new(),
                photo_folder: String::new(),
                audio_folder: String::new(),
                skip_existing: true,
                check_mode: CheckMode::Fast,
                cloud: None,
                mirror_prefix: Some(rel.clone()),
                assets: None,
            };
            let plan = engine::plan(&st.catalog, &spec, &scan, &cancel, &sink)?;
            let mut r = engine::execute(&st.catalog, &plan, &cancel, &sink);
            r.finished_at = chrono::Utc::now().timestamp();
            r.finish();
            if r.copied_count > 0 || r.failures > 0 {
                r.reports = engine::write_reports(&r, &scan);
            }
            Ok(if r.failures > 0 {
                format!("Backup of {name}: {} files failed.", r.failures)
            } else {
                format!("Backup of {name} done: {} files copied ({}).", r.copied_count, util::byte_text(r.copied_bytes))
            })
        })()
        .unwrap_or_else(|e| format!("Backup of {name} failed: {e}"));
        *st.backup_task.lock().unwrap() = TaskState { running: false, message: Some(msg), ..Default::default() };
        let _ = app.emit("projects-changed", ());
        emit(&app);
    });
    Ok(())
}

#[tauri::command]
fn get_downloads(source: String, days: u32) -> Vec<library::DownloadItem> {
    library::downloads(&source, days)
}

#[tauri::command]
fn project_options(st: State<Shared>) -> Vec<String> {
    library::project_options(&st.settings.lock().unwrap())
}

#[tauri::command]
async fn copy_downloads(app: AppHandle, items: Vec<String>, project: String, subfolder: String, move_originals: bool) -> Result<String, String> {
    let s = app.state::<Shared>().settings.lock().unwrap().clone();
    tauri::async_runtime::spawn_blocking(move || library::copy_downloads(&s, &items, &project, &subfolder, move_originals)).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn share_copy_files(paths: Vec<String>) -> Result<(), String> {
    library::copy_files_to_clipboard(&paths)
}

#[tauri::command]
fn share_whatsapp(app: AppHandle, paths: Vec<String>) -> Result<String, String> {
    library::copy_files_to_clipboard(&paths)?;
    let _ = app.opener().open_url("whatsapp://", None::<&str>);
    Ok("Files copied. Open a chat in WhatsApp and paste (Ctrl+V). For big videos, a Google Drive link works better.".into())
}

#[tauri::command]
fn share_email(app: AppHandle, paths: Vec<String>, subject: String) -> Result<String, String> {
    let size: u64 = paths.iter().map(|p| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)).sum();
    if size > 20_000_000 {
        return Err(format!("Too big for email ({}). Use a Google Drive link instead.", util::byte_text(size)));
    }
    library::copy_files_to_clipboard(&paths)?;
    let url = format!("mailto:?subject={}", subject.replace(' ', "%20"));
    let _ = app.opener().open_url(url, None::<&str>);
    Ok("Your mail app opened and the files are on the clipboard. Paste them into the message (Ctrl+V).".into())
}

#[tauri::command]
fn share_drive_link(st: State<Shared>, app: AppHandle, paths: Vec<String>) -> Result<(), String> {
    let s = st.settings.lock().unwrap().clone();
    if let Some(i) = cloud_issue(&s) {
        return Err(i);
    }
    {
        let mut t = st.share_task.lock().unwrap();
        if t.running {
            return Err("A link is already being made".into());
        }
        *t = TaskState { running: true, label: "Getting ready…".into(), ..Default::default() };
    }
    emit(&app);
    let st = st.inner().clone();
    std::thread::spawn(move || {
        let app2 = app.clone();
        let st2 = st.clone();
        let res = library::drive_links(&s, &paths, cloud_spec(&s), &move |m| {
            st2.share_task.lock().unwrap().label = m;
            emit(&app2);
        });
        let mut t = st.share_task.lock().unwrap();
        t.running = false;
        match res {
            Ok(l) => {
                t.links = l;
                t.error = None;
            }
            Err(e) => t.error = Some(e),
        }
        drop(t);
        emit(&app);
    });
    Ok(())
}

#[tauri::command]
fn clear_share(st: State<Shared>, app: AppHandle) {
    *st.share_task.lock().unwrap() = TaskState::default();
    emit(&app);
}

#[tauri::command]
fn copy_text(text: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        clipboard_win::set_clipboard_string(&text).map_err(|e| e.to_string())
    }
    #[cfg(not(windows))]
    {
        use std::io::Write;
        let mut c = std::process::Command::new("pbcopy").stdin(std::process::Stdio::piped()).spawn().map_err(|e| e.to_string())?;
        c.stdin.as_mut().unwrap().write_all(text.as_bytes()).map_err(|e| e.to_string())?;
        c.wait().map_err(|e| e.to_string())?;
        Ok(())
    }
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn list_remotes() -> Vec<String> {
    cloud::list_remotes()
}

#[tauri::command]
fn connect_google(st: State<Shared>, app: AppHandle) -> Result<(), String> {
    let s = st.settings.lock().unwrap().clone();
    {
        let mut t = st.connect_task.lock().unwrap();
        if t.running {
            return Ok(());
        }
        *t = TaskState { running: true, label: "Your browser opens. Sign in with your Google account, then click Allow.".into(), ..Default::default() };
    }
    emit(&app);
    let st = st.inner().clone();
    std::thread::spawn(move || {
        let res = cloud::connect_own(s.cloud_client_id.trim(), s.cloud_client_secret.trim(), &Cancel::new());
        let mut t = st.connect_task.lock().unwrap();
        t.running = false;
        t.message = Some(match &res {
            Ok(_) => "Google account connected.".into(),
            Err(e) => format!("Not connected: {e}"),
        });
        drop(t);
        if res.is_ok() {
            let mut s = st.settings.lock().unwrap();
            s.cloud_enabled = true;
            save_settings_file(&s);
        }
        emit(&app);
    });
    Ok(())
}

#[tauri::command]
fn disconnect_google(st: State<Shared>, app: AppHandle) {
    cloud::disconnect_own();
    st.connect_task.lock().unwrap().message = Some("Account disconnected from BCKUP.".into());
    emit(&app);
}

#[tauri::command]
fn desktop_drive_folders() -> Vec<String> {
    // Google Drive for desktop: a "G:" drive (Windows) or ~/Library/CloudStorage/GoogleDrive-* (macOS).
    let mut out = vec![];
    if cfg!(windows) {
        for l in b'D'..=b'Z' {
            for name in ["My Drive", "Drive Saya", "Meine Ablage", "Mon Drive", "Mi unidad"] {
                let p = format!("{}:\\{name}", l as char);
                if Path::new(&p).is_dir() {
                    out.push(p);
                }
            }
        }
    } else if let Some(h) = dirs::home_dir() {
        let base = h.join("Library/CloudStorage");
        for a in library::list_dirs(&base).into_iter().filter(|a| a.starts_with("GoogleDrive-")) {
            let acc = base.join(&a);
            let my = library::list_dirs(&acc).into_iter().find(|n| ["My Drive", "Drive Saya", "Meine Ablage", "Mon Drive", "Mi unidad"].contains(&n.as_str()));
            out.push(acc.join(my.unwrap_or_default()).to_string_lossy().to_string());
        }
    }
    out
}

#[tauri::command]
fn use_desktop_drive(st: State<Shared>, app: AppHandle, folder: String) -> Result<(), String> {
    let target = Path::new(&folder).join("BCKUP Backup");
    std::fs::create_dir_all(&target).map_err(|e| e.to_string())?;
    let t = target.to_string_lossy().to_string();
    let mut s = st.settings.lock().unwrap();
    if !s.backup_roots.contains(&t) {
        s.backup_roots.push(t);
    }
    save_settings_file(&s);
    drop(s);
    emit(&app);
    Ok(())
}

#[tauri::command]
fn show_main(app: AppHandle) {
    show_main_window(&app);
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(w) = app.get_webview_window("panel") {
        let _ = w.hide();
    }
}

#[tauri::command]
fn log_js(message: String) {
    eprintln!("[js] {message}");
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

// MARK: - Windows, tray, drive watcher

fn show_main_window(app: &AppHandle) {
    if let Some(p) = app.get_webview_window("panel") {
        let _ = p.hide();
    }
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

fn show_panel(app: &AppHandle, anchor: Option<(f64, f64, f64, f64)>) {
    let Some(w) = app.get_webview_window("panel") else { return };
    let size = w.outer_size().unwrap_or(tauri::PhysicalSize::new(380, 520));
    let (pw, ph) = (size.width as f64, size.height as f64);
    let pos = match anchor {
        Some((x, y, aw, ah)) => {
            let cx = x + aw / 2.0 - pw / 2.0;
            if cfg!(windows) { (cx, y - ph - 8.0) } else { (cx, y + ah + 6.0) }
        }
        None => {
            // No click position (a card just went in): bottom-right on Windows, top-right on macOS.
            if let Ok(Some(m)) = w.current_monitor() {
                let ms = m.size();
                let mp = m.position();
                if cfg!(windows) {
                    (mp.x as f64 + ms.width as f64 - pw - 16.0, mp.y as f64 + ms.height as f64 - ph - 64.0)
                } else {
                    (mp.x as f64 + ms.width as f64 - pw - 16.0, mp.y as f64 + 40.0)
                }
            } else {
                (100.0, 100.0)
            }
        }
    };
    let _ = w.set_position(tauri::PhysicalPosition::new(pos.0.max(0.0), pos.1.max(0.0)));
    let _ = w.show();
    let _ = w.set_focus();
    let _ = app.emit("state", ());
}

fn refresh_volumes(app: &AppHandle, st: &App, announce: bool) {
    let vols = drives::list();
    let mut prev = st.volumes.lock().unwrap();
    let before: Vec<String> = prev.iter().map(|v| v.path.clone()).collect();
    let changed = *prev != vols;
    let new_cards: Vec<String> = vols.iter().filter(|v| v.is_card && !before.contains(&v.path)).map(|v| v.path.clone()).collect();
    *prev = vols.clone();
    drop(prev);
    // Forget idle jobs for cards that were unplugged.
    let present: Vec<String> = vols.iter().map(|v| v.path.clone()).collect();
    let manual: Vec<String> = st.manual.lock().unwrap().iter().map(|m| m.0.clone()).collect();
    st.jobs.lock().unwrap().retain(|k, j| present.contains(k) || manual.contains(k) || j.busy());
    if changed {
        emit(app);
    }
    if announce {
        let auto = st.settings.lock().unwrap().auto_open_on_card;
        for c in new_cards {
            let shared: Shared = app.state::<Shared>().inner().clone();
            start_scan(app.clone(), shared, c.clone());
            let _ = app.emit("card-inserted", c);
            if auto {
                show_panel(app, None);
            }
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let shared: Shared = Arc::new(App {
        settings: Mutex::new(load_settings()),
        catalog: Arc::new(Catalog::open(&util::data_dir().join("catalog.sqlite"))),
        jobs: Mutex::new(HashMap::new()),
        manual: Mutex::new(vec![]),
        volumes: Mutex::new(vec![]),
        notices: Mutex::new(vec![]),
        backup_task: Mutex::new(TaskState::default()),
        share_task: Mutex::new(TaskState::default()),
        connect_task: Mutex::new(TaskState::default()),
        last_emit: AtomicU64::new(0),
    });

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(shared.clone())
        .on_page_load(|w, p| eprintln!("[page] {} {:?} {}", w.label(), p.event(), p.url()))
        .invoke_handler(tauri::generate_handler![
            get_state, get_job, update_form, rescan, check_job, start_job, cancel_job, reset_job, run_quick_check, eject,
            save_settings, choose_primary, add_backup, choose_source, add_dropped, remove_source, hide_volume, dismiss_notice,
            open_path, reveal, open_side_by_side, get_projects, backup_project, get_downloads, project_options, copy_downloads,
            share_copy_files, share_whatsapp, share_email, share_drive_link, clear_share, copy_text, open_url, list_remotes,
            connect_google, disconnect_google, desktop_drive_folders, use_desktop_drive, show_main, hide_panel, quit, log_js
        ])
        .setup(move |app| {
            if let Ok(dir) = app.path().resource_dir() {
                cloud::set_resource_dir(dir);
            }
            let handle = app.handle().clone();

            let open = MenuItem::with_id(app, "open", "Open BCKUP", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit BCKUP", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &quit])?;
            TrayIconBuilder::with_id("tray")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("BCKUP")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, e| match e.id.as_ref() {
                    "open" => show_main_window(app),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = e {
                        let app = tray.app_handle();
                        if let Some(w) = app.get_webview_window("panel") {
                            if w.is_visible().unwrap_or(false) {
                                let _ = w.hide();
                                return;
                            }
                            let scale = w.scale_factor().unwrap_or(1.0);
                            let p = rect.position.to_physical::<f64>(scale);
                            let s = rect.size.to_physical::<f64>(scale);
                            show_panel(app, Some((p.x, p.y, s.width, s.height)));
                        }
                    }
                })
                .build(app)?;

            // Closing the main window keeps BCKUP running in the tray; the panel hides when it loses focus.
            if let Some(main) = app.get_webview_window("main") {
                let m2 = main.clone();
                let h2 = handle.clone();
                main.on_window_event(move |e| match e {
                    WindowEvent::CloseRequested { api, .. } => {
                        api.prevent_close();
                        let _ = m2.hide();
                    }
                    WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) => {
                        let key = add_sources(&h2, paths.iter().map(|p| p.to_string_lossy().to_string()).collect());
                        let _ = h2.emit("select-source", key);
                    }
                    _ => {}
                });
            }
            if let Some(panel) = app.get_webview_window("panel") {
                let p2 = panel.clone();
                panel.on_window_event(move |e| {
                    if let WindowEvent::Focused(false) = e {
                        let _ = p2.hide();
                    }
                });
            }

            // Files or folders passed on the command line ("Open with BCKUP").
            let args: Vec<String> = std::env::args().skip(1).filter(|a| !a.starts_with('-') && Path::new(a).exists()).collect();
            if !args.is_empty() {
                let key = add_sources(&handle, args);
                let _ = handle.emit("select-source", key);
            }

            // Reading drives can block (a sleeping disk, a permission prompt), so never do it on the UI thread.
            let st = shared.clone();
            let h3 = handle.clone();
            std::thread::spawn(move || {
                refresh_volumes(&h3, &st, false);
                let cards: Vec<String> = st.volumes.lock().unwrap().iter().filter(|v| v.is_card).map(|v| v.path.clone()).collect();
                for c in cards {
                    start_scan(h3.clone(), st.clone(), c);
                }
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    refresh_volumes(&h3, &st, true);
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running BCKUP");
}
