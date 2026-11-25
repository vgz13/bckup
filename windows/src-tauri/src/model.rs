//! Data shared between the engine and the web UI.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum FileKind {
    Video,
    Photo,
    Audio,
    Sidecar,
    Other,
}

impl FileKind {
    pub fn is_media(self) -> bool {
        matches!(self, FileKind::Video | FileKind::Photo | FileKind::Audio)
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum DatePosition {
    After,
    Before,
    None,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CheckMode {
    Thorough,
    Fast,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CloudMode {
    OwnAccount,
    ExistingRemote,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub primary_root: Option<String>,
    pub backup_roots: Vec<String>,
    pub use_client_folder: bool,
    pub date_position: DatePosition,
    pub date_format: String,
    pub separate_by_type: bool,
    pub video_folder: String,
    pub photo_folder: String,
    pub audio_folder: String,
    pub material_folder: String,
    pub split_material: bool,
    pub group_by_device: bool,
    pub material_names: HashMap<String, String>,
    pub skip_existing: bool,
    pub check_mode: CheckMode,
    pub cloud_enabled: bool,
    pub cloud_mode: CloudMode,
    pub cloud_client_id: String,
    pub cloud_client_secret: String,
    pub cloud_remote: String,
    pub cloud_path: String,
    pub auto_open_on_card: bool,
    pub hidden_volumes: Vec<String>,
    pub last_project: String,
    pub last_used: i64,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            primary_root: None,
            backup_roots: vec![],
            use_client_folder: false,
            date_position: DatePosition::After,
            date_format: "%d.%m.%y".into(),
            separate_by_type: true,
            video_folder: "Video".into(),
            photo_folder: "Photo".into(),
            audio_folder: "Audio".into(),
            material_folder: "MATERIAL".into(),
            split_material: true,
            group_by_device: true,
            material_names: HashMap::new(),
            skip_existing: true,
            check_mode: CheckMode::Thorough,
            cloud_enabled: false,
            cloud_mode: CloudMode::OwnAccount,
            cloud_client_id: String::new(),
            cloud_client_secret: String::new(),
            cloud_remote: String::new(),
            cloud_path: "Footage".into(),
            auto_open_on_card: true,
            hidden_volumes: vec![],
            last_project: String::new(),
            last_used: 0,
        }
    }
}

impl Settings {
    pub fn asset_layout(&self) -> AssetLayout {
        let f = crate::util::clean_name(&self.material_folder);
        let names = ASSET_CATEGORIES
            .iter()
            .map(|(k, d)| {
                let n = crate::util::clean_name(self.material_names.get(*k).map(String::as_str).unwrap_or(""));
                (k.to_string(), if n.is_empty() { d.to_string() } else { n })
            })
            .collect();
        AssetLayout { folder: if f.is_empty() { "MATERIAL".into() } else { f }, split: self.split_material, by_device: self.group_by_device, names }
    }

    pub fn kind_folder(&self, k: FileKind) -> Option<&str> {
        match k {
            FileKind::Video => Some(&self.video_folder),
            FileKind::Photo => Some(&self.photo_folder),
            FileKind::Audio => Some(&self.audio_folder),
            _ => None,
        }
    }
}

/// Asset categories inside MATERIAL: (key, default folder name).
pub const ASSET_CATEGORIES: &[(&str, &str)] = &[
    ("video", "Video"),
    ("photo", "Photo"),
    ("audio", "Audio"),
    ("graphics", "Graphics"),
    ("documents", "Documents"),
    ("fonts", "Fonts"),
    ("projectFiles", "Project Files"),
    ("archives", "Archives"),
    ("other", "Other"),
];

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetLayout {
    pub folder: String,
    pub split: bool,
    pub by_device: bool,
    pub names: HashMap<String, String>,
}

impl AssetLayout {
    /// MATERIAL / Video / iPhone 15 Pro / <the file's own relative path>
    pub fn rel(&self, path: &std::path::Path, rel: &str) -> String {
        let mut parts = vec![self.folder.clone()];
        if self.split {
            let anchor = crate::scanner::sidecar_partner(path).unwrap_or_else(|| path.to_path_buf());
            let c = crate::scanner::asset_category(&anchor);
            parts.push(self.names.get(c).cloned().unwrap_or_else(|| c.to_string()));
            if self.by_device && (c == "video" || c == "photo") {
                if let Some(d) = crate::scanner::device_for(&anchor) {
                    parts.push(crate::util::clean_name(&d));
                }
            }
        }
        parts.push(rel.to_string());
        parts.into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("/")
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CardFile {
    pub path: String,
    pub rel: String,
    pub size: u64,
    pub mtime: f64,
    pub kind: FileKind,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CardScan {
    pub root: String,
    pub name: String,
    pub files: Vec<CardFile>,
    pub camera: String,
    pub model: Option<String>,
    pub total_bytes: u64,
    pub counts: HashMap<String, usize>,
    pub suggested_date: f64,
    pub first_date: Option<f64>,
    pub last_date: Option<f64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloudSpec {
    pub rclone: String,
    pub remote: String,
    pub path: String,
    pub extra_args: Vec<String>,
}

impl CloudSpec {
    pub fn target(&self) -> String {
        let r = if self.remote.ends_with(':') { self.remote.clone() } else { format!("{}:", self.remote) };
        let p = self.path.trim_matches(|c| c == '/' || c == ' ');
        if p.is_empty() { r } else { format!("{r}{p}") }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OffloadSpec {
    pub client_folder: Option<String>,
    pub project_folder: String,
    pub roll: String,
    pub destinations: Vec<String>,
    pub separate_by_type: bool,
    pub video_folder: String,
    pub photo_folder: String,
    pub audio_folder: String,
    pub skip_existing: bool,
    pub check_mode: CheckMode,
    pub cloud: Option<CloudSpec>,
    pub mirror_prefix: Option<String>,
    #[serde(default)]
    pub assets: Option<AssetLayout>,
}

impl OffloadSpec {
    pub fn project_rel(&self) -> String {
        [self.client_folder.clone().unwrap_or_default(), self.project_folder.clone()]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join("/")
    }

    pub fn target_rel(&self, f: &CardFile, routed: FileKind) -> String {
        if let Some(m) = &self.mirror_prefix {
            return if m.is_empty() { f.rel.clone() } else { format!("{m}/{}", f.rel) };
        }
        if let Some(a) = &self.assets {
            return [self.project_rel(), a.rel(std::path::Path::new(&f.path), &f.rel)].into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("/");
        }
        let mut parts = vec![self.project_rel()];
        if self.separate_by_type {
            let k = match routed {
                FileKind::Video => self.video_folder.clone(),
                FileKind::Photo => self.photo_folder.clone(),
                FileKind::Audio => self.audio_folder.clone(),
                _ => String::new(),
            };
            if !k.is_empty() {
                parts.push(k);
            }
        }
        if !self.roll.is_empty() {
            parts.push(self.roll.clone());
        }
        parts.push(f.rel.clone());
        parts.into_iter().filter(|s| !s.is_empty()).collect::<Vec<_>>().join("/")
    }
}

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum DestAction {
    Skip { existing: String, verified: bool },
    Copy { target: String, renamed: bool },
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanItem {
    pub file: CardFile,
    pub routed: FileKind,
    pub actions: HashMap<String, DestAction>,
    pub card_hash: Option<String>,
}

impl PlanItem {
    pub fn needs_copy(&self) -> bool {
        self.actions.values().any(|a| matches!(a, DestAction::Copy { .. }))
    }
    pub fn renamed(&self) -> bool {
        self.actions.values().any(|a| matches!(a, DestAction::Copy { renamed: true, .. }))
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DestSummary {
    pub root: String,
    pub name: String,
    pub skip: usize,
    pub copy: usize,
    pub bytes: u64,
    pub renamed: usize,
    pub free: Option<u64>,
    pub total: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OffloadPlan {
    pub spec: OffloadSpec,
    pub items: Vec<PlanItem>,
    pub summaries: Vec<DestSummary>,
    pub files_to_copy: usize,
    pub bytes_to_copy: u64,
    pub renamed_count: usize,
    pub space_problem: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum DestOutcome {
    Existing { rel: String, verified: bool },
    Copied { rel: String },
    Failed { message: String },
}

impl DestOutcome {
    pub fn is_safe(&self) -> bool {
        match self {
            DestOutcome::Copied { .. } => true,
            DestOutcome::Existing { verified, .. } => *verified,
            DestOutcome::Failed { .. } => false,
        }
    }
    pub fn is_present(&self) -> bool {
        !matches!(self, DestOutcome::Failed { .. })
    }
    pub fn rel(&self) -> Option<&str> {
        match self {
            DestOutcome::Copied { rel } | DestOutcome::Existing { rel, .. } => Some(rel),
            _ => None,
        }
    }
    pub fn label(&self) -> String {
        match self {
            DestOutcome::Copied { .. } => "Copied & verified".into(),
            DestOutcome::Existing { verified: true, .. } => "Already there (contents match)".into(),
            DestOutcome::Existing { verified: false, .. } => "Already there (quick check)".into(),
            DestOutcome::Failed { message } => format!("Failed: {message}"),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ItemResult {
    pub file: CardFile,
    pub hash: Option<String>,
    pub outcomes: HashMap<String, DestOutcome>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Verdict {
    pub kind: String,
    pub title: String,
    pub detail: String,
    pub good: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OffloadResult {
    pub spec: OffloadSpec,
    pub items: Vec<ItemResult>,
    pub cancelled: bool,
    pub cloud_ok: Option<bool>,
    pub cloud_message: Option<String>,
    pub reports: Vec<String>,
    pub started_at: i64,
    pub finished_at: i64,
    pub copied_count: usize,
    pub copied_bytes: u64,
    pub existing_count: usize,
    pub failures: usize,
    pub verdict: Option<Verdict>,
}

impl OffloadResult {
    pub fn finish(&mut self) {
        self.failures = self.items.iter().filter(|i| i.outcomes.values().any(|o| matches!(o, DestOutcome::Failed { .. }))).count();
        let copied: Vec<&ItemResult> = self.items.iter().filter(|i| i.outcomes.values().any(|o| matches!(o, DestOutcome::Copied { .. }))).collect();
        self.copied_count = copied.len();
        self.copied_bytes = copied.iter().map(|i| i.file.size).sum();
        self.existing_count = self
            .items
            .iter()
            .filter(|i| !i.outcomes.is_empty() && i.outcomes.values().all(|o| matches!(o, DestOutcome::Existing { .. })))
            .count();
        self.verdict = Some(self.compute_verdict());
    }

    fn compute_verdict(&self) -> Verdict {
        let v = |kind: &str, title: String, detail: &str, good: bool| Verdict { kind: kind.into(), title, detail: detail.into(), good };
        if self.items.is_empty() {
            return v("empty", "Empty card".into(), "There are no files on this card.", false);
        }
        if self.cancelled {
            return v("cancelled", "Cancelled".into(), "The copy stopped. Files that didn't finish were not saved under their real names.", false);
        }
        if self.failures > 0 {
            return v("failed", format!("{} files failed", self.failures), "Don't format the card. See the failed files below, then try again.", false);
        }
        let cloud = if self.cloud_ok == Some(true) { 1 } else { 0 };
        let min_present = self.items.iter().map(|i| i.outcomes.values().filter(|o| o.is_present()).count() + cloud).min().unwrap_or(0);
        let min_safe = self.items.iter().map(|i| i.outcomes.values().filter(|o| o.is_safe()).count() + cloud).min().unwrap_or(0);
        if min_safe >= 2 {
            return v("safe", "Safe to format".into(), &format!("Every file is in {min_safe} places and its contents were checked. You can format the card."), true);
        }
        if min_present >= 2 {
            return v("unverified", "Probably safe".into(), "Some files were counted as already there by a quick check, without comparing contents. Check again in Thorough mode before formatting.", false);
        }
        v("oneCopy", "Only 1 copy".into(), "Every file is safe in one place, but there's no second copy yet. Don't format the card until there's a backup.", false)
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub phase: String,
    pub detail: String,
    pub done: u64,
    pub total: u64,
    pub is_bytes: bool,
    pub file_index: usize,
    pub file_count: usize,
    pub file_name: String,
}
