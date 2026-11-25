//! Low-level helpers: cancel flag, uncached reads, hashing, copying with read-back verification, disk space.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use xxhash_rust::xxh64::Xxh64;

pub const CHUNK: usize = 8 << 20;

#[derive(Clone, Default)]
pub struct Cancel(Arc<AtomicBool>);

impl Cancel {
    pub fn new() -> Self {
        Cancel(Arc::new(AtomicBool::new(false)))
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst)
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

pub const CANCELLED: &str = "__cancelled__";

/// A buffer aligned to 4 KiB, needed for unbuffered reads on Windows.
pub struct AlignedBuf {
    raw: Vec<u8>,
    off: usize,
}

impl AlignedBuf {
    pub fn new(size: usize) -> Self {
        let raw = vec![0u8; size + 4096];
        let addr = raw.as_ptr() as usize;
        let off = (4096 - (addr % 4096)) % 4096;
        AlignedBuf { raw, off }
    }
    pub fn slice(&mut self) -> &mut [u8] {
        let end = self.raw.len() - 4096 + self.off;
        &mut self.raw[self.off..end]
    }
}

/// Opens a file for reading straight from the disk, not the OS cache, so verification really re-reads the bytes.
pub fn open_uncached(path: &Path) -> std::io::Result<File> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_NO_BUFFERING: u32 = 0x2000_0000;
        const FILE_FLAG_SEQUENTIAL_SCAN: u32 = 0x0800_0000;
        match OpenOptions::new().read(true).custom_flags(FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN).open(path) {
            Ok(f) => Ok(f),
            Err(_) => File::open(path),
        }
    }
    #[cfg(not(windows))]
    {
        let f = File::open(path)?;
        #[cfg(target_os = "macos")]
        unsafe {
            use std::os::unix::io::AsRawFd;
            libc::fcntl(f.as_raw_fd(), libc::F_NOCACHE, 1);
        }
        Ok(f)
    }
}

fn open_for_write(path: &Path) -> std::io::Result<File> {
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_FLAG_WRITE_THROUGH: u32 = 0x8000_0000;
        OpenOptions::new().write(true).create(true).truncate(true).custom_flags(FILE_FLAG_WRITE_THROUGH).open(path)
    }
    #[cfg(not(windows))]
    {
        let f = OpenOptions::new().write(true).create(true).truncate(true).open(path)?;
        #[cfg(target_os = "macos")]
        unsafe {
            use std::os::unix::io::AsRawFd;
            libc::fcntl(f.as_raw_fd(), libc::F_NOCACHE, 1);
        }
        Ok(f)
    }
}

fn read_full(f: &mut File, buf: &mut [u8]) -> std::io::Result<usize> {
    // Unbuffered reads may return less than asked; keep reading until the buffer is full or EOF.
    let mut n = 0;
    while n < buf.len() {
        match f.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

pub fn hex(v: u64) -> String {
    format!("{v:016x}")
}

pub fn hash_file(path: &Path, cancel: Option<&Cancel>, mut progress: impl FnMut(u64)) -> Result<String, String> {
    let name = path.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let mut f = open_uncached(path).map_err(|e| format!("Couldn't open {name}: {e}"))?;
    let mut buf = AlignedBuf::new(CHUNK);
    let mut h = Xxh64::new(0);
    loop {
        if cancel.map(|c| c.is_cancelled()).unwrap_or(false) {
            return Err(CANCELLED.into());
        }
        let n = read_full(&mut f, buf.slice()).map_err(|e| format!("Couldn't read {name}: {e}"))?;
        if n == 0 {
            break;
        }
        h.update(&buf.slice()[..n]);
        progress(n as u64);
        if n < CHUNK {
            break;
        }
    }
    Ok(hex(h.digest()))
}

pub struct CopyOutcome {
    pub hash: String,
    pub finals: Vec<Option<PathBuf>>,
    pub errors: Vec<Option<String>>,
}

pub fn unique_path(p: &Path) -> PathBuf {
    let dir = p.parent().map(Path::to_path_buf).unwrap_or_default();
    let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let ext = p.extension().map(|s| s.to_string_lossy().to_string());
    let mut n = 2;
    loop {
        let name = match &ext {
            Some(e) => format!("{stem}_{n}.{e}"),
            None => format!("{stem}_{n}"),
        };
        let c = dir.join(name);
        if !c.exists() {
            return c;
        }
        n += 1;
    }
}

/// Reads the source once, writes every target, then reads each target back from disk and compares hashes.
/// Unfinished files keep a hidden temporary name and are removed on failure.
pub fn copy_verified(
    src: &Path,
    targets: &[PathBuf],
    mtime: f64,
    cancel: &Cancel,
    mut progress: impl FnMut(u64, &str),
) -> Result<CopyOutcome, String> {
    let name = src.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let mut input = open_uncached(src).map_err(|e| format!("Couldn't read {name} from the card: {e}"))?;
    let mut errors: Vec<Option<String>> = vec![None; targets.len()];
    let mut parts: Vec<PathBuf> = Vec::new();
    let mut outs: Vec<Option<File>> = Vec::new();
    for (i, t) in targets.iter().enumerate() {
        let dir = t.parent().map(Path::to_path_buf).unwrap_or_default();
        let part = dir.join(format!(".{}.bckup-part", t.file_name().unwrap_or_default().to_string_lossy()));
        parts.push(part.clone());
        if let Err(e) = fs::create_dir_all(&dir) {
            errors[i] = Some(format!("Couldn't make the folder: {e}"));
            outs.push(None);
            continue;
        }
        let _ = fs::remove_file(&part);
        match open_for_write(&part) {
            Ok(f) => outs.push(Some(f)),
            Err(e) => {
                errors[i] = Some(format!("Couldn't write: {e}"));
                outs.push(None)
            }
        }
    }
    let cleanup = |parts: &Vec<PathBuf>| {
        for p in parts {
            let _ = fs::remove_file(p);
        }
    };

    let mut buf = AlignedBuf::new(CHUNK);
    let mut h = Xxh64::new(0);
    loop {
        if cancel.is_cancelled() {
            drop(outs);
            cleanup(&parts);
            return Err(CANCELLED.into());
        }
        let n = match read_full(&mut input, buf.slice()) {
            Ok(n) => n,
            Err(e) => {
                drop(outs);
                cleanup(&parts);
                return Err(format!("Couldn't read the card: {e}"));
            }
        };
        if n == 0 {
            break;
        }
        let data = &buf.slice()[..n];
        h.update(data);
        let active: Vec<usize> = (0..outs.len()).filter(|&i| outs[i].is_some() && errors[i].is_none()).collect();
        if active.is_empty() {
            break;
        }
        if active.len() == 1 {
            let i = active[0];
            if let Err(e) = outs[i].as_mut().unwrap().write_all(data) {
                errors[i] = Some(format!("Couldn't write: {e}"));
            }
        } else {
            let results: Vec<(usize, Option<String>)> = std::thread::scope(|s| {
                let handles: Vec<_> = outs
                    .iter_mut()
                    .enumerate()
                    .filter(|(i, o)| o.is_some() && errors[*i].is_none())
                    .map(|(i, o)| {
                        let f = o.as_mut().unwrap();
                        s.spawn(move || (i, f.write_all(data).err().map(|e| format!("Couldn't write: {e}"))))
                    })
                    .collect();
                handles.into_iter().map(|h| h.join().unwrap()).collect()
            });
            for (i, e) in results {
                if e.is_some() {
                    errors[i] = e;
                }
            }
        }
        progress(n as u64, "Copying");
        if n < CHUNK {
            break;
        }
    }
    for (i, o) in outs.iter_mut().enumerate() {
        if let Some(f) = o.take() {
            if errors[i].is_none() {
                if let Err(e) = f.sync_all() {
                    errors[i] = Some(format!("Couldn't save to disk: {e}"));
                }
            }
        }
    }
    let hash = hex(h.digest());

    for i in 0..targets.len() {
        if errors[i].is_some() {
            continue;
        }
        match hash_file(&parts[i], Some(cancel), |n| progress(n, "Verifying")) {
            Ok(v) if v == hash => {}
            Ok(_) => errors[i] = Some("The copy doesn't match the card (different hash)".into()),
            Err(e) if e == CANCELLED => {
                cleanup(&parts);
                return Err(CANCELLED.into());
            }
            Err(e) => errors[i] = Some(format!("Verification failed: {e}")),
        }
    }

    let mut finals = vec![None; targets.len()];
    let ft = filetime::FileTime::from_unix_time(mtime as i64, ((mtime.fract()) * 1e9) as u32);
    for i in 0..targets.len() {
        if errors[i].is_some() {
            let _ = fs::remove_file(&parts[i]);
            continue;
        }
        let _ = filetime::set_file_mtime(&parts[i], ft);
        let mut fin = targets[i].clone();
        if fin.exists() {
            fin = unique_path(&fin);
        }
        match fs::rename(&parts[i], &fin) {
            Ok(_) => finals[i] = Some(fin),
            Err(e) => {
                errors[i] = Some(format!("Couldn't give the file its final name: {e}"));
                let _ = fs::remove_file(&parts[i]);
            }
        }
    }
    Ok(CopyOutcome { hash, finals, errors })
}

/// (free, total) bytes of the volume holding `path`.
pub fn disk_space(path: &str) -> Option<(u64, u64)> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
        let wide: Vec<u16> = std::ffi::OsStr::new(path).encode_wide().chain(Some(0)).collect();
        let (mut avail, mut total, mut free) = (0u64, 0u64, 0u64);
        let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut avail, &mut total, &mut free) };
        if ok != 0 { Some((avail, total)) } else { None }
    }
    #[cfg(unix)]
    {
        let c = std::ffi::CString::new(path).ok()?;
        let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c.as_ptr(), &mut s) } == 0 {
            Some((s.f_bavail as u64 * s.f_frsize as u64, s.f_blocks as u64 * s.f_frsize as u64))
        } else {
            None
        }
    }
}

/// Root of the volume a path is on: "E:\" on Windows, "/Volumes/X" on macOS.
pub fn volume_root(path: &str) -> String {
    #[cfg(windows)]
    {
        let p = path.replace('/', "\\");
        if p.len() >= 2 && p.as_bytes()[1] == b':' {
            return format!("{}\\", &p[..2].to_uppercase());
        }
        p
    }
    #[cfg(not(windows))]
    {
        let comps: Vec<&str> = path.split('/').collect();
        if comps.len() > 2 && comps[1] == "Volumes" {
            return format!("/Volumes/{}", comps[2]);
        }
        "/".into()
    }
}

pub fn volume_label(path: &str) -> String {
    let root = volume_root(path);
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::GetVolumeInformationW;
        let wide: Vec<u16> = std::ffi::OsStr::new(&root).encode_wide().chain(Some(0)).collect();
        let mut name = [0u16; 261];
        let ok = unsafe {
            GetVolumeInformationW(wide.as_ptr(), name.as_mut_ptr(), name.len() as u32, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), 0)
        };
        let label = if ok != 0 { String::from_utf16_lossy(&name[..name.iter().position(|&c| c == 0).unwrap_or(0)]) } else { String::new() };
        let letter = root.trim_end_matches('\\').to_string();
        if label.is_empty() { format!("Local Disk ({letter})") } else { format!("{label} ({letter})") }
    }
    #[cfg(not(windows))]
    {
        if root == "/" { "Macintosh HD".into() } else { root.trim_start_matches("/Volumes/").into() }
    }
}

pub fn clean_name(s: &str) -> String {
    s.replace(['/', '\\', ':', '*', '?', '"', '<', '>', '|'], "-").trim().to_string()
}

pub fn rel_path(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| path.file_name().unwrap_or_default().to_string_lossy().to_string())
}

pub fn mtime_of(meta: &fs::Metadata) -> f64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

pub fn byte_text(n: u64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1000.0 && i < units.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 { format!("{n} bytes") } else { format!("{v:.1} {}", units[i]) }
}

pub fn data_dir() -> PathBuf {
    let d = match std::env::var("BCKUP_DATA_DIR") {
        Ok(t) => PathBuf::from(t),
        Err(_) => dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("BCKUP"),
    };
    let _ = fs::create_dir_all(&d);
    d
}
