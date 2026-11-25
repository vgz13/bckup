//! Finding plugged-in cards and drives, and ejecting them.

use crate::scanner;
use crate::util;
use serde::Serialize;
use std::path::Path;

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Volume {
    pub path: String,
    pub name: String,
    pub id: String,
    pub is_card: bool,
    pub removable: bool,
    pub total: u64,
    pub free: u64,
    pub system: bool,
}

/// Every mounted volume except the system disk itself.
pub fn list() -> Vec<Volume> {
    let mut out = vec![];
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{GetDriveTypeW, GetLogicalDrives, GetVolumeInformationW};
        const DRIVE_REMOVABLE: u32 = 2;
        const DRIVE_FIXED: u32 = 3;
        let mask = unsafe { GetLogicalDrives() };
        let sys = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into()).to_uppercase();
        for i in 0..26u32 {
            if mask & (1 << i) == 0 {
                continue;
            }
            let letter = (b'A' + i as u8) as char;
            let root = format!("{letter}:\\");
            let wide: Vec<u16> = std::ffi::OsStr::new(&root).encode_wide().chain(Some(0)).collect();
            let t = unsafe { GetDriveTypeW(wide.as_ptr()) };
            if t != DRIVE_REMOVABLE && t != DRIVE_FIXED {
                continue;
            }
            let mut serial = 0u32;
            let mut name = [0u16; 261];
            let ok = unsafe {
                GetVolumeInformationW(wide.as_ptr(), name.as_mut_ptr(), 261, &mut serial, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), 0)
            };
            if ok == 0 {
                continue; // empty card reader slot
            }
            let (free, total) = util::disk_space(&root).unwrap_or((0, 0));
            let system = format!("{letter}:") == sys;
            out.push(Volume {
                path: root.clone(),
                name: util::volume_label(&root),
                id: format!("{serial:08X}"),
                is_card: !system && scanner::looks_like_card(Path::new(&root)),
                removable: t == DRIVE_REMOVABLE,
                total,
                free,
                system,
            });
        }
    }
    #[cfg(not(windows))]
    {
        if let Ok(rd) = std::fs::read_dir("/Volumes") {
            for e in rd.flatten() {
                let p = e.path();
                let fname = e.file_name().to_string_lossy().to_string();
                if fname.starts_with('.') || fname == "Recovery" {
                    continue;
                }
                let Ok(meta) = std::fs::symlink_metadata(&p) else { continue };
                if meta.file_type().is_symlink() {
                    continue; // "Macintosh HD" link to /
                }
                let path = p.to_string_lossy().to_string();
                let (free, total) = util::disk_space(&path).unwrap_or((0, 0));
                let home = dirs::home_dir().map(|h| h.to_string_lossy().to_string()).unwrap_or_default();
                let system = home == path || home.starts_with(&format!("{path}/"));
                out.push(Volume {
                    name: util::volume_label(&path),
                    id: path.clone(),
                    is_card: !system && scanner::looks_like_card(&p),
                    removable: true,
                    total,
                    free,
                    system,
                    path,
                });
            }
        }
    }
    out
}

pub fn eject(path: &str) -> Result<(), String> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let letter = path.trim_end_matches('\\');
        let script = format!("(New-Object -ComObject Shell.Application).Namespace(17).ParseName('{letter}').InvokeVerb('Eject')");
        let st = std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", &script])
            .creation_flags(0x0800_0000)
            .status()
            .map_err(|e| e.to_string())?;
        std::thread::sleep(std::time::Duration::from_millis(1500));
        if st.success() && !Path::new(path).exists() {
            Ok(())
        } else if Path::new(path).exists() {
            Err("Windows didn't eject the card. Close any window using it and try again.".into())
        } else {
            Ok(())
        }
    }
    #[cfg(not(windows))]
    {
        let st = std::process::Command::new("diskutil").args(["eject", path]).status().map_err(|e| e.to_string())?;
        if st.success() { Ok(()) } else { Err("Couldn't eject the card".into()) }
    }
}
