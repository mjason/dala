#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
mod windows {
    use std::env;
    use std::ffi::{OsStr, OsString};
    use std::fs::{self, File, OpenOptions};
    use std::io::Write;
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};
    use std::time::{SystemTime, UNIX_EPOCH};

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    const MAX_LOG_BYTES: u64 = 10 * 1024 * 1024;

    pub fn main() {
        let args: Vec<OsString> = env::args_os().skip(1).collect();
        let log_hint = args.get(1).map(PathBuf::from);

        let exit_code = match run(&args) {
            Ok(code) => code,
            Err(error) => {
                write_launcher_error(log_hint.as_deref(), &error);
                1
            }
        };

        std::process::exit(exit_code);
    }

    fn run(args: &[OsString]) -> Result<i32, String> {
        let [runner, log_path] = args else {
            return Err("usage: dala_task_launcher.exe RUNNER.ps1 LOG_FILE".to_string());
        };

        let runner = PathBuf::from(runner);
        let log_path = PathBuf::from(log_path);
        if !runner.is_file() {
            return Err(format!("runner does not exist: {}", runner.display()));
        }

        prepare_log(&log_path)?;
        let mut log = open_log(&log_path)?;
        let _ = writeln!(log, "\n=== Dala task start {} ===", unix_timestamp());
        let stderr = log
            .try_clone()
            .map_err(|error| format!("clone log handle: {error}"))?;

        let install_root = runner
            .parent()
            .ok_or_else(|| format!("runner has no parent directory: {}", runner.display()))?;

        let status = Command::new(system_powershell())
            .args([
                OsStr::new("-NoProfile"),
                OsStr::new("-NonInteractive"),
                OsStr::new("-ExecutionPolicy"),
                OsStr::new("Bypass"),
                OsStr::new("-File"),
            ])
            .arg(&runner)
            .env("DALA_HOME", install_root)
            .current_dir(install_root)
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(stderr))
            .creation_flags(CREATE_NO_WINDOW)
            .status()
            .map_err(|error| format!("start {}: {error}", runner.display()))?;

        Ok(status.code().unwrap_or(1))
    }

    fn system_powershell() -> PathBuf {
        let system_root =
            env::var_os("SystemRoot").unwrap_or_else(|| OsString::from(r"C:\Windows"));
        PathBuf::from(system_root).join(r"System32\WindowsPowerShell\v1.0\powershell.exe")
    }

    fn prepare_log(path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create log directory {}: {error}", parent.display()))?;
        }

        let should_rotate = fs::metadata(path)
            .map(|metadata| metadata.len() >= MAX_LOG_BYTES)
            .unwrap_or(false);

        if should_rotate {
            let rotated = path.with_extension("log.old");
            let _ = fs::remove_file(&rotated);
            let _ = fs::rename(path, rotated);
        }

        Ok(())
    }

    fn open_log(path: &Path) -> Result<File, String> {
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|error| format!("open log {}: {error}", path.display()))
    }

    fn write_launcher_error(log_hint: Option<&Path>, error: &str) {
        let fallback = env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(env::temp_dir)
            .join(r"Dala\logs\server.log");
        let path = log_hint.unwrap_or(&fallback);
        let _ = prepare_log(path);

        if let Ok(mut log) = open_log(path) {
            let _ = writeln!(log, "dala_task_launcher: {error}");
        }
    }

    fn unix_timestamp() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .unwrap_or(0)
    }
}

#[cfg(windows)]
fn main() {
    windows::main();
}

#[cfg(not(windows))]
fn main() {}
