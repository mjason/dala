#![cfg(windows)]

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use sysinfo::{Pid, ProcessesToUpdate, System};
use windows_sys::Win32::System::Console::{AttachConsole, FreeConsole, GetConsoleWindow};
use windows_sys::Win32::UI::WindowsAndMessaging::IsWindowVisible;

const T_HELLO: u8 = 0x01;
const T_OUTPUT: u8 = 0x02;
const T_PROCESSES: u8 = 0x08;
const T_AUTH: u8 = 0x10;
const T_INPUT: u8 = 0x11;
const T_KILL: u8 = 0x13;
const T_PROCESSES_REQ: u8 = 0x16;

// WMI process creation and ConPTY teardown are host-global operations on the
// Windows runner. Running multiple holder sessions concurrently makes the
// tests race each other's provider/console cleanup, producing false socket
// timeouts and stale process observations. Keep the real process tests
// independent while serializing that host-global resource.
static HOLDER_TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn holder_test_guard() -> std::sync::MutexGuard<'static, ()> {
    HOLDER_TEST_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap()
}

fn temp_root() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "dala-holder-windows-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    ));
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn write_frame(stream: &mut TcpStream, frame_type: u8, payload: &[u8]) {
    let length = (payload.len() + 1) as u32;
    stream.write_all(&length.to_be_bytes()).unwrap();
    stream.write_all(&[frame_type]).unwrap();
    stream.write_all(payload).unwrap();
    stream.flush().unwrap();
}

fn read_frame(stream: &mut TcpStream) -> std::io::Result<(u8, Vec<u8>)> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header)?;
    let mut payload = vec![0_u8; u32::from_be_bytes(header) as usize];
    stream.read_exact(&mut payload)?;
    Ok((payload[0], payload[1..].to_vec()))
}

fn wait_endpoint(path: &PathBuf) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Ok(body) = std::fs::read(path) {
            if let Ok(endpoint) = serde_json::from_slice(&body) {
                return endpoint;
            }
        }
        assert!(
            Instant::now() < deadline,
            "holder endpoint was not published"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_processes_exit(pids: &[Pid]) {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut system = System::new();

    loop {
        system.refresh_processes(ProcessesToUpdate::All, true);
        let running: Vec<_> = pids
            .iter()
            .copied()
            .filter(|pid| system.process(*pid).is_some())
            .collect();

        if running.is_empty() {
            return;
        }

        assert!(
            Instant::now() < deadline,
            "holder process tree did not exit: {running:?}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_child_exit(child: &mut Child, timeout: Duration) -> ExitStatus {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("child process did not exit within {timeout:?}");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn detached_holder_does_not_show_a_host_console() {
    let _holder_test_guard = holder_test_guard();
    let root = temp_root();
    let endpoint_path = root.join("hidden-session.sock");
    let token = "windows-hidden-holder-test-token";
    let config = serde_json::json!({
        "socket": endpoint_path,
        "token": token,
        "shell": std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".into()),
        "args": ["/D", "/Q", "/K", "rem"],
        "cwd": root,
        "rows": 24,
        "cols": 80,
        "history_lines": 1000
    });

    let status = Command::new(env!("CARGO_BIN_EXE_dala_holder"))
        .arg(config.to_string())
        .status()
        .unwrap();
    assert!(status.success(), "launcher process failed: {status}");

    let endpoint = wait_endpoint(&endpoint_path);
    let port = endpoint["port"].as_u64().unwrap() as u16;
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write_frame(&mut stream, T_AUTH, token.as_bytes());
    let (kind, hello) = read_frame(&mut stream).unwrap();
    assert_eq!(kind, T_HELLO);

    let hello: serde_json::Value = serde_json::from_slice(&hello).unwrap();
    assert_eq!(hello["proto"], 7);
    let shell_pid = Pid::from_u32(hello["pid"].as_u64().unwrap() as u32);
    let mut system = System::new();
    system.refresh_processes(ProcessesToUpdate::All, true);
    let holder_pid = system
        .process(shell_pid)
        .and_then(|process| process.parent())
        .expect("shell parent holder process was not found");

    let probe = Command::new(std::env::current_exe().unwrap())
        .args(["console_probe_helper", "--exact"])
        .env("DALA_CONSOLE_PROBE_PID", holder_pid.as_u32().to_string())
        .output()
        .unwrap();

    write_frame(&mut stream, T_KILL, b"");
    let deadline = Instant::now() + Duration::from_secs(5);
    while endpoint_path.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
    }
    wait_processes_exit(&[holder_pid, shell_pid]);
    let _ = std::fs::remove_dir_all(root);

    assert!(
        probe.status.success(),
        "holder shows a host console:\n{}",
        String::from_utf8_lossy(&probe.stdout)
    );
}

#[test]
fn console_probe_helper() {
    let Ok(raw_pid) = std::env::var("DALA_CONSOLE_PROBE_PID") else {
        return;
    };
    let pid = raw_pid.parse::<u32>().unwrap();

    unsafe {
        FreeConsole();
    }
    let attached = unsafe { AttachConsole(pid) } != 0;
    let visible = attached && unsafe { IsWindowVisible(GetConsoleWindow()) } != 0;
    if attached {
        unsafe {
            FreeConsole();
        }
    }

    assert!(!visible, "process {pid} has a visible host console");
}

#[test]
fn detached_cmd_session_authenticates_and_round_trips_terminal_io() {
    let _holder_test_guard = holder_test_guard();
    let root = temp_root();
    let endpoint_path = root.join("session.sock");
    let token = "windows-holder-test-token";
    let config = serde_json::json!({
        "socket": endpoint_path,
        "token": token,
        "shell": std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".into()),
        "args": ["/D", "/Q", "/K", "rem"],
        "cwd": root,
        "rows": 24,
        "cols": 80,
        "history_lines": 1000,
        "env": [
            ["TERM", "xterm-256color"],
            ["COLORTERM", "truecolor"],
            ["WARP_CLI_AGENT_PROTOCOL_VERSION", "1"],
            ["WARP_CLIENT_VERSION", "dala"],
            ["PROMPT", "$E]7;file://localhost/$P$E\\$P$G"]
        ],
        "env_remove": ["TERM_PROGRAM", "WT_SESSION", "WT_PROFILE_ID"]
    });

    let status = Command::new(env!("CARGO_BIN_EXE_dala_holder"))
        .arg(config.to_string())
        .status()
        .unwrap();
    assert!(status.success(), "launcher process failed: {status}");

    let endpoint = wait_endpoint(&endpoint_path);
    let port = endpoint["port"].as_u64().unwrap() as u16;

    let mut rejected = TcpStream::connect(("127.0.0.1", port)).unwrap();
    rejected
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    write_frame(&mut rejected, T_AUTH, b"wrong-token");
    assert!(read_frame(&mut rejected).is_err());

    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write_frame(&mut stream, T_AUTH, token.as_bytes());
    assert_eq!(read_frame(&mut stream).unwrap().0, T_HELLO);
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        endpoint_path.exists(),
        "idle cmd session exited after startup"
    );

    // Browser terminal Enter is a single carriage return, not CRLF.
    write_frame(&mut stream, T_INPUT, b"echo DALA_WINDOWS_OK\r");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut output = Vec::new();
    while !output
        .windows(b"DALA_WINDOWS_OK".len())
        .any(|window| window == b"DALA_WINDOWS_OK")
    {
        let (kind, payload) = read_frame(&mut stream).unwrap();
        if kind == T_OUTPUT {
            output.extend(payload);
        }
        assert!(Instant::now() < deadline, "command output never arrived");
    }

    write_frame(&mut stream, T_INPUT, b"echo executed>cr-enter.txt\r");
    let entered = root.join("cr-enter.txt");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut entered_contents = String::new();
    while Instant::now() < deadline {
        entered_contents = std::fs::read_to_string(&entered).unwrap_or_default();
        if entered_contents.trim() == "executed" {
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert_eq!(entered_contents.trim(), "executed");

    write_frame(
        &mut stream,
        T_INPUT,
        b"powershell.exe -NoProfile -Command \"Start-Sleep -Seconds 5\"\r\n",
    );
    std::thread::sleep(Duration::from_millis(300));
    let request_id = 42_u64;
    write_frame(&mut stream, T_PROCESSES_REQ, &request_id.to_be_bytes());
    let processes = loop {
        let (kind, payload) = read_frame(&mut stream).unwrap();
        if kind == T_PROCESSES {
            break payload;
        }
    };
    assert_eq!(&processes[..8], &request_id.to_be_bytes());
    let processes: serde_json::Value = serde_json::from_slice(&processes[8..]).unwrap();
    assert!(
        processes.as_array().unwrap().iter().any(|process| {
            process["argv"].as_array().is_some_and(|argv| {
                argv.iter()
                    .any(|arg| arg.as_str().is_some_and(|arg| arg.contains("Start-Sleep")))
            })
        }),
        "process tree did not include PowerShell: {processes}"
    );

    // A rollback can reconnect an older BEAM to this protocol-7 holder. Its
    // request has no correlation id and must receive the original plain JSON
    // shape without disconnecting the surviving shell.
    write_frame(&mut stream, T_PROCESSES_REQ, b"");
    let legacy_processes = loop {
        let (kind, payload) = read_frame(&mut stream).unwrap();
        if kind == T_PROCESSES {
            break payload;
        }
    };
    assert!(serde_json::from_slice::<Vec<serde_json::Value>>(&legacy_processes).is_ok());

    write_frame(&mut stream, T_KILL, b"");
    let deadline = Instant::now() + Duration::from_secs(5);
    while endpoint_path.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(
        !endpoint_path.exists(),
        "holder did not clean up its endpoint"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn exec_proxy_preserves_argv_stdout_and_redirects_stderr() {
    let _holder_test_guard = holder_test_guard();
    let root = temp_root();
    let stderr_path = root.join("child.stderr");
    let script = "echo proxy-out & echo proxy-error 1>&2";
    let config = serde_json::json!({
        "command": [
            std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".into()),
            "/D",
            "/S",
            "/C",
            script
        ],
        "stderr": stderr_path,
    });

    let mut proxy = Command::new(env!("CARGO_BIN_EXE_dala_holder"))
        .arg("exec")
        .arg(config.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let _stdin = proxy.stdin.take().unwrap();
    let output = proxy.wait_with_output().unwrap();

    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains("proxy-out"));
    assert!(std::fs::read_to_string(&stderr_path)
        .unwrap()
        .contains("proxy-error"));
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn exec_proxy_closes_its_job_before_joining_stdout_from_cmd_descendants() {
    let _holder_test_guard = holder_test_guard();
    let root = temp_root();
    let wrapper_path = root.join("spawn-descendant.cmd");
    let pid_path = root.join("descendant.pid");
    let stderr_path = root.join("proxy.stderr");
    std::fs::write(
        &wrapper_path,
        "@echo off\r\nstart \"\" /B powershell.exe -NoProfile -NonInteractive -Command \"$PID | Set-Content -NoNewline -Encoding ascii '%~dp0descendant.pid'; Start-Sleep -Seconds 60\"\r\n:wait_for_pid\r\nif not exist \"%~dp0descendant.pid\" (\r\n  ping -n 2 127.0.0.1 >nul\r\n  goto wait_for_pid\r\n)\r\nset /p DALA_UNUSED=\r\necho wrapper-out\r\n",
    )
    .unwrap();
    let config = serde_json::json!({
        "command": [wrapper_path],
        "stderr": stderr_path,
    });

    let mut proxy = Command::new(env!("CARGO_BIN_EXE_dala_holder"))
        .arg("exec")
        .arg(config.to_string())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let proxy_stdin = proxy.stdin.take().unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    let descendant_pid = loop {
        if let Ok(contents) = std::fs::read_to_string(&pid_path) {
            if let Ok(pid) = contents.trim().parse::<u32>() {
                break pid;
            }
        }
        assert!(
            Instant::now() < deadline,
            ".cmd descendant did not publish its pid"
        );
        std::thread::sleep(Duration::from_millis(20));
    };

    drop(proxy_stdin);
    let status = wait_child_exit(&mut proxy, Duration::from_secs(5));
    assert!(status.success(), "exec proxy failed: {status}");
    wait_processes_exit(&[Pid::from_u32(descendant_pid)]);

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn installed_agent_cmd_shims_execute_inside_conpty() {
    let _holder_test_guard = holder_test_guard();
    let Ok(raw_commands) = std::env::var("DALA_WINDOWS_AGENT_COMMANDS") else {
        return;
    };
    let commands: Vec<_> = raw_commands
        .split(',')
        .map(str::trim)
        .filter(|command| !command.is_empty())
        .collect();
    assert!(!commands.is_empty(), "no agent commands were configured");

    let root = temp_root();
    let endpoint_path = root.join("agents.sock");
    let token = "windows-agent-probe-token";
    let config = serde_json::json!({
        "socket": endpoint_path,
        "token": token,
        "shell": std::env::var("COMSPEC").unwrap_or_else(|_| "cmd.exe".into()),
        "args": ["/D", "/Q", "/K", "rem"],
        "cwd": root,
        "rows": 30,
        "cols": 120,
        "history_lines": 1000
    });

    let status = Command::new(env!("CARGO_BIN_EXE_dala_holder"))
        .arg(config.to_string())
        .status()
        .unwrap();
    assert!(status.success(), "launcher process failed: {status}");

    let endpoint = wait_endpoint(&endpoint_path);
    let port = endpoint["port"].as_u64().unwrap() as u16;
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(60)))
        .unwrap();
    write_frame(&mut stream, T_AUTH, token.as_bytes());
    assert_eq!(read_frame(&mut stream).unwrap().0, T_HELLO);

    let mut failures = Vec::new();
    for command in commands {
        let marker = format!("DALA_AGENT_OK_{}", command.to_ascii_uppercase());
        let input = format!("where {command} >nul && {command} --version && echo {marker}\r");
        write_frame(&mut stream, T_INPUT, input.as_bytes());

        let deadline = Instant::now() + Duration::from_secs(60);
        let mut output = Vec::new();
        while !output
            .windows(marker.len())
            .any(|window| window == marker.as_bytes())
            && Instant::now() < deadline
        {
            match read_frame(&mut stream) {
                Ok((T_OUTPUT, payload)) => output.extend(payload),
                Ok(_) => {}
                Err(_) => break,
            }
        }

        if !output
            .windows(marker.len())
            .any(|window| window == marker.as_bytes())
        {
            failures.push(format!("{command}: {}", String::from_utf8_lossy(&output)));
        }
    }

    write_frame(&mut stream, T_KILL, b"");
    let deadline = Instant::now() + Duration::from_secs(5);
    while endpoint_path.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
    }
    let _ = std::fs::remove_dir_all(root);

    assert!(
        failures.is_empty(),
        "agent ConPTY probes failed:\n{}",
        failures.join("\n")
    );
}
