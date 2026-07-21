#![cfg(windows)]

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn fixture_dir() -> PathBuf {
    let id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("dala-task-launcher-{id}"))
}

#[test]
fn powershell_child_has_no_console_window() {
    let dir = fixture_dir();
    fs::create_dir_all(&dir).expect("create fixture dir");
    let script = dir.join("probe.ps1");
    let result = dir.join("console.txt");
    let log = dir.join("server.log");

    fs::write(
        &script,
        r#"Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DalaConsoleProbe {
  [DllImport("kernel32.dll")]
  public static extern IntPtr GetConsoleWindow();
}
"@
[IO.File]::WriteAllText($env:DALA_CONSOLE_PROBE, [DalaConsoleProbe]::GetConsoleWindow().ToInt64().ToString())
"#,
    )
    .expect("write probe script");

    let status = Command::new(env!("CARGO_BIN_EXE_dala_task_launcher"))
        .args([&script, &log])
        .env("DALA_CONSOLE_PROBE", &result)
        .status()
        .expect("start task launcher");

    assert!(status.success());
    assert_eq!(fs::read_to_string(&result).expect("read probe"), "0");
    assert!(fs::read_to_string(&log)
        .expect("read launcher log")
        .contains("Dala task start"));

    fs::remove_dir_all(dir).expect("remove fixture dir");
}

#[test]
fn child_exit_code_is_returned_to_task_scheduler() {
    let dir = fixture_dir();
    fs::create_dir_all(&dir).expect("create fixture dir");
    let script = dir.join("exit.ps1");
    let log = dir.join("server.log");
    fs::write(&script, "exit 23\n").expect("write exit script");

    let status = Command::new(env!("CARGO_BIN_EXE_dala_task_launcher"))
        .args([&script, &log])
        .status()
        .expect("start task launcher");

    assert_eq!(status.code(), Some(23));
    fs::remove_dir_all(dir).expect("remove fixture dir");
}
