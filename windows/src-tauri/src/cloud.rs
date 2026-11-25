//! Google Drive through rclone: BCKUP's own sign-in (separate config), uploads, MD5 checks and share links.

use crate::util::{data_dir, Cancel};
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};

pub const OWN_REMOTE: &str = "bckup-gdrive";

static RESOURCE_DIR: Mutex<Option<PathBuf>> = Mutex::new(None);

pub fn set_resource_dir(p: PathBuf) {
    *RESOURCE_DIR.lock().unwrap() = Some(p);
}

pub fn own_config_path() -> PathBuf {
    data_dir().join("rclone.conf")
}

pub fn own_config_args() -> Vec<String> {
    vec!["--config".into(), own_config_path().to_string_lossy().to_string()]
}

pub fn own_connected() -> bool {
    std::fs::read_to_string(own_config_path()).map(|s| s.contains(&format!("[{OWN_REMOTE}]")) && s.contains("token")).unwrap_or(false)
}

pub fn find_rclone() -> Option<String> {
    let exe = if cfg!(windows) { "rclone.exe" } else { "rclone" };
    if let Some(dir) = RESOURCE_DIR.lock().unwrap().clone() {
        for c in [dir.join(exe), dir.join("resources").join(exe)] {
            if c.is_file() {
                return Some(c.to_string_lossy().to_string());
            }
        }
    }
    let mut cands: Vec<PathBuf> = vec![];
    if cfg!(windows) {
        if let Some(h) = dirs::home_dir() {
            cands.push(h.join("scoop/shims/rclone.exe"));
        }
        cands.push(PathBuf::from(r"C:\Program Files\rclone\rclone.exe"));
    } else {
        cands.extend(["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone"].map(PathBuf::from));
    }
    if let Ok(path) = std::env::var("PATH") {
        for d in std::env::split_paths(&path) {
            cands.push(d.join(exe));
        }
    }
    cands.into_iter().find(|p| p.is_file()).map(|p| p.to_string_lossy().to_string())
}

fn command(exe: &str) -> Command {
    let mut c = Command::new(exe);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console flashing up
    }
    c
}

pub struct RunResult {
    pub status: i32,
    pub lines: Vec<String>,
}

impl RunResult {
    pub fn last(&self) -> String {
        self.lines.last().cloned().unwrap_or_else(|| format!("exit code {}", self.status))
    }
}

/// Runs rclone, handing each output line (stdout + stderr) to `on_line`.
pub fn run(exe: &str, args: &[String], cancel: &Cancel, on_line: impl Fn(&str) + Send + Sync + 'static) -> RunResult {
    let mut child = match command(exe).args(args).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(c) => c,
        Err(e) => return RunResult { status: -1, lines: vec![format!("Couldn't run rclone: {e}")] },
    };
    let lines = Arc::new(Mutex::new(Vec::<String>::new()));
    let cb = Arc::new(on_line);
    let mut readers = vec![];
    let streams: Vec<Box<dyn Read + Send>> = vec![Box::new(child.stdout.take().unwrap()), Box::new(child.stderr.take().unwrap())];
    for s in streams {
        let lines = lines.clone();
        let cb = cb.clone();
        readers.push(std::thread::spawn(move || {
            let mut r = BufReader::new(s);
            let mut buf = Vec::new();
            loop {
                buf.clear();
                match r.read_until(b'\n', &mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        for part in String::from_utf8_lossy(&buf).split('\r') {
                            let l = part.trim();
                            if !l.is_empty() {
                                cb(l);
                                let mut v = lines.lock().unwrap();
                                v.push(l.to_string());
                                if v.len() > 400 {
                                    v.remove(0);
                                }
                            }
                        }
                    }
                }
            }
        }));
    }
    let status = loop {
        if cancel.is_cancelled() {
            let _ = child.kill();
        }
        match child.try_wait() {
            Ok(Some(s)) => break s.code().unwrap_or(-1),
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(200)),
            Err(_) => break -1,
        }
    };
    for r in readers {
        let _ = r.join();
    }
    let lines = lines.lock().unwrap().clone();
    RunResult { status, lines }
}

fn run_json(exe: &str, args: &[String], cancel: &Cancel) -> (i32, String, Vec<String>) {
    let mut child = match command(exe).args(args).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn() {
        Ok(c) => c,
        Err(e) => return (-1, String::new(), vec![e.to_string()]),
    };
    let mut out = child.stdout.take().unwrap();
    let mut err = child.stderr.take().unwrap();
    let t1 = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = out.read_to_string(&mut s);
        s
    });
    let t2 = std::thread::spawn(move || {
        let mut s = String::new();
        let _ = err.read_to_string(&mut s);
        s
    });
    let status = loop {
        if cancel.is_cancelled() {
            let _ = child.kill();
        }
        match child.try_wait() {
            Ok(Some(s)) => break s.code().unwrap_or(-1),
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(200)),
            Err(_) => break -1,
        }
    };
    let o = t1.join().unwrap_or_default();
    let e = t2.join().unwrap_or_default();
    (status, o, e.lines().map(String::from).collect())
}

pub fn list_remotes() -> Vec<String> {
    let Some(rc) = find_rclone() else { return vec![] };
    let r = run(&rc, &["listremotes".to_string()], &Cancel::new(), |_| {});
    if r.status != 0 {
        return vec![];
    }
    r.lines.into_iter().filter(|l| l.ends_with(':')).collect()
}

/// Opens the browser so whoever uses this computer signs in to their own Google account.
/// Walks rclone's non-interactive config questions: accepts the shared client_id notice
/// (only asked without an own client_id), uses the local browser for OAuth, defaults otherwise.
pub fn connect_own(client_id: &str, client_secret: &str, cancel: &Cancel) -> Result<(), String> {
    let rc = find_rclone().ok_or("rclone isn't included in this app")?;
    let _ = std::fs::create_dir_all(data_dir());
    let mut del = own_config_args();
    del.extend(["config".into(), "delete".into(), OWN_REMOTE.into()]);
    let _ = run(&rc, &del, &Cancel::new(), |_| {});

    let mut base = own_config_args();
    base.extend(["config", "create", OWN_REMOTE, "drive", "scope=drive"].map(String::from));
    if !client_id.is_empty() {
        base.push(format!("client_id={client_id}"));
    }
    if !client_secret.is_empty() {
        base.push(format!("client_secret={client_secret}"));
    }
    base.push("--non-interactive".into());
    let mut args = base.clone();
    for _ in 0..12 {
        if cancel.is_cancelled() {
            return Err("Cancelled".into());
        }
        let (status, out, err) = run_json(&rc, &args, cancel);
        if status != 0 {
            return Err(err.last().cloned().unwrap_or_else(|| format!("rclone exit code {status}")));
        }
        let v: serde_json::Value = serde_json::from_str(&out).map_err(|_| "Couldn't read rclone's answer".to_string())?;
        if let Some(e) = v.get("Error").and_then(|e| e.as_str()).filter(|e| !e.is_empty()) {
            return Err(e.to_string());
        }
        let state = v.get("State").and_then(|s| s.as_str()).unwrap_or("");
        if state.is_empty() {
            return if own_connected() { Ok(()) } else { Err("Sign-in didn't finish".into()) };
        }
        let opt = v.get("Option");
        let name = opt.and_then(|o| o.get("Name")).and_then(|n| n.as_str()).unwrap_or("");
        let answer = match name {
            "config_shared_client_id" | "config_is_local" => "true".to_string(),
            _ => match opt.and_then(|o| o.get("Default")) {
                Some(serde_json::Value::String(s)) => s.clone(),
                Some(serde_json::Value::Bool(b)) => b.to_string(),
                Some(serde_json::Value::Number(n)) => n.to_string(),
                _ => String::new(),
            },
        };
        args = base.clone();
        args.extend(["--continue".into(), "--state".into(), state.into(), "--result".into(), answer]);
    }
    Err("rclone setup didn't finish".into())
}

pub fn disconnect_own() {
    if let Some(rc) = find_rclone() {
        let mut a = own_config_args();
        a.extend(["config".into(), "delete".into(), OWN_REMOTE.into()]);
        let _ = run(&rc, &a, &Cancel::new(), |_| {});
    }
}

pub fn percent(line: &str) -> Option<u64> {
    let i = line.find('%')?;
    let start = line[..i].rfind(|c: char| !c.is_ascii_digit()).map(|j| j + 1).unwrap_or(0);
    line[start..i].parse().ok()
}
