//! Per-session PTY holder (dtach model).
//!
//! Holds one PTY + shell independently of the dala BEAM so terminals survive
//! server restarts. dala connects over a unix socket; frames are 4-byte
//! big-endian length prefixed (matching Erlang's `packet: 4`) with a 1-byte
//! type tag:
//!
//!   holder -> client:  0x01 HELLO   {json: pid,rows,cols,proto}
//!                      0x02 OUTPUT  <raw bytes>
//!                      0x03 EXIT    <u32 be status>
//!                      0x04 REPAINT <synthesized screen bytes>
//!   client -> holder:  0x11 INPUT   <raw bytes>
//!                      0x12 RESIZE  <u16 be rows> <u16 be cols>
//!                      0x13 KILL
//!                      0x14 REPAINT_REQ
//!
//! The holder embeds a headless terminal emulator (alacritty_terminal): all
//! PTY output feeds a server-side grid + scrollback. REPAINT_REQ answers
//! with a bounded synthesized repaint (history tail + screen + cursor +
//! modes) — the tmux attach model — so clients never replay raw history.
//! Ordering: pending OUTPUT is flushed before the REPAINT is generated, so a
//! repaint always covers exactly the bytes already sent.
//!
//! One client at a time; a new connection kicks the old one. Output produced
//! while no client is attached accumulates in a bounded ring and is flushed
//! on (re)connect. When the shell exits the holder writes `{socket}.exit`
//! with the status (for a dala that reconnects later), best-effort sends
//! EXIT, unlinks the socket and exits.

mod screen;

use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::exit;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::Deserialize;

use crate::screen::Screen;

const T_HELLO: u8 = 0x01;
const T_OUTPUT: u8 = 0x02;
const T_EXIT: u8 = 0x03;
const T_REPAINT: u8 = 0x04;
const T_INPUT: u8 = 0x11;
const T_RESIZE: u8 = 0x12;
const T_KILL: u8 = 0x13;
const T_REPAINT_REQ: u8 = 0x14;

/// Cap on buffered (undelivered) output. Old bytes are dropped first; dala's
/// scrollback is the durable history, this only bridges reconnect gaps.
const RING_MAX: usize = 8 * 1024 * 1024;
const CHUNK: usize = 64 * 1024;

#[derive(Deserialize)]
struct Config {
    socket: String,
    shell: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    cwd: String,
    #[serde(default)]
    env: Vec<(String, String)>,
    #[serde(default)]
    env_remove: Vec<String>,
    rows: u16,
    cols: u16,
    #[serde(default = "default_history_lines")]
    history_lines: usize,
}

fn default_history_lines() -> usize {
    10_000
}

struct Shared {
    ring: VecDeque<u8>,
    client: Option<UnixStream>,
    /// Bumped per accepted connection so stale threads/writes can tell they
    /// lost the client race and must not clear a newer connection.
    client_gen: u64,
    exit_status: Option<u32>,
    /// Server-side emulator: grid + scrollback + modes.
    screen: Screen,
    /// Repaints requested by the client, served once the ring is drained.
    repaint_pending: u32,
}

struct State {
    shared: Mutex<Shared>,
    cond: Condvar,
}

fn main() {
    let arg = std::env::args().nth(1).unwrap_or_else(|| usage());
    let config: Config = serde_json::from_str(&arg).unwrap_or_else(|e| {
        eprintln!("dala_holder: bad config json: {e}");
        exit(2);
    });

    reset_signals();

    let socket_path = PathBuf::from(&config.socket);
    if let Some(dir) = socket_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // A live holder for this session means we must not double-spawn; a stale
    // socket is the spawner's job to clear before launching us.
    let listener = match UnixListener::bind(&socket_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("dala_holder: bind {}: {e}", socket_path.display());
            exit(3);
        }
    };

    daemonize(&socket_path);

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: config.rows,
            cols: config.cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap_or_else(|e| fatal(&socket_path, &format!("openpty: {e}")));

    let mut cmd = CommandBuilder::new(&config.shell);
    cmd.args(&config.args);
    if !config.cwd.is_empty() {
        cmd.cwd(&config.cwd);
    }
    for (key, value) in &config.env {
        cmd.env(key, value);
    }
    for key in &config.env_remove {
        cmd.env_remove(key);
    }

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .unwrap_or_else(|e| fatal(&socket_path, &format!("spawn {}: {e}", config.shell)));
    drop(pair.slave);

    let shell_pid = child.process_id().unwrap_or(0);
    let killer: Arc<Mutex<Box<dyn ChildKiller + Send + Sync>>> =
        Arc::new(Mutex::new(child.clone_killer()));
    let mut pty_reader = pair
        .master
        .try_clone_reader()
        .unwrap_or_else(|e| fatal(&socket_path, &format!("clone reader: {e}")));
    let pty_writer = pair
        .master
        .take_writer()
        .unwrap_or_else(|e| fatal(&socket_path, &format!("take writer: {e}")));
    let pty_writer = Arc::new(Mutex::new(pty_writer));
    // Kept for resize; unix PTY masters are fd wrappers, access is serialized.
    let master: Arc<Mutex<SendMaster>> = Arc::new(Mutex::new(SendMaster(pair.master)));

    let state = Arc::new(State {
        shared: Mutex::new(Shared {
            ring: VecDeque::new(),
            client: None,
            client_gen: 0,
            exit_status: None,
            screen: Screen::new(config.rows, config.cols, config.history_lines),
            repaint_pending: 0,
        }),
        cond: Condvar::new(),
    });

    // PTY -> ring.
    {
        let state = Arc::clone(&state);
        thread::spawn(move || {
            let mut buf = [0u8; 16384];
            loop {
                match pty_reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let mut shared = state.shared.lock().unwrap();
                        shared.screen.advance(&buf[..n]);
                        // The emulator is the durable history; the ring only
                        // carries live bytes to the attached client.
                        if shared.client.is_some() {
                            shared.ring.extend(&buf[..n]);
                            let excess = shared.ring.len().saturating_sub(RING_MAX);
                            if excess > 0 {
                                shared.ring.drain(..excess);
                            }
                        }
                        state.cond.notify_all();
                    }
                    // EIO once the child side is gone.
                    Err(_) => break,
                }
            }

            let status = child.wait().map(|s| s.exit_code()).unwrap_or(0);
            let mut shared = state.shared.lock().unwrap();
            shared.exit_status = Some(status);
            state.cond.notify_all();
        });
    }

    // Ring -> client writer; also owns shutdown once the shell has exited.
    {
        let state = Arc::clone(&state);
        let socket_path = socket_path.clone();
        thread::spawn(move || {
            enum Job {
                Output(Vec<u8>),
                Repaint(Vec<u8>),
                Exit(u32, Vec<u8>),
            }

            loop {
                let (job, stream, gen) = {
                    let mut shared = state.shared.lock().unwrap();
                    loop {
                        let attached = shared.client.is_some();
                        let drainable = attached && !shared.ring.is_empty();
                        let repaint = attached && shared.ring.is_empty() && shared.repaint_pending > 0;
                        let done = shared.exit_status.is_some() && shared.ring.is_empty();
                        if drainable || repaint || done {
                            break;
                        }
                        shared = state.cond.wait(shared).unwrap();
                    }

                    let stream = shared.client.as_ref().and_then(|s| s.try_clone().ok());
                    let gen = shared.client_gen;

                    if shared.client.is_some() && !shared.ring.is_empty() {
                        let n = shared.ring.len().min(CHUNK);
                        (Job::Output(shared.ring.drain(..n).collect()), stream, gen)
                    } else if shared.client.is_some() && shared.repaint_pending > 0 {
                        shared.repaint_pending -= 1;
                        (Job::Repaint(shared.screen.repaint()), stream, gen)
                    } else {
                        let status = shared.exit_status.unwrap_or(0);
                        (Job::Exit(status, shared.screen.repaint()), stream, gen)
                    }
                };

                match job {
                    Job::Output(chunk) => {
                        if let Some(mut stream) = stream {
                            if write_frame(&mut stream, T_OUTPUT, &chunk).is_err() {
                                let mut shared = state.shared.lock().unwrap();
                                // Undeliverable: park the bytes back for the next client.
                                for byte in chunk.iter().rev() {
                                    shared.ring.push_front(*byte);
                                }
                                if shared.client_gen == gen {
                                    shared.client = None;
                                }
                            }
                        }
                    }
                    Job::Repaint(repaint) => {
                        if let Some(mut stream) = stream {
                            if write_frame(&mut stream, T_REPAINT, &repaint).is_err() {
                                let mut shared = state.shared.lock().unwrap();
                                if shared.client_gen == gen {
                                    shared.client = None;
                                }
                            }
                        }
                    }
                    Job::Exit(status, final_screen) => {
                        // Durable first: a dala that is down right now finds the
                        // status and the last screen on reattach.
                        let _ = std::fs::write(exit_path(&socket_path), status.to_string());
                        let _ = std::fs::write(final_path(&socket_path), &final_screen);
                        if let Some(mut stream) = stream {
                            let _ = write_frame(&mut stream, T_EXIT, &status.to_be_bytes());
                        }
                        let _ = std::fs::remove_file(&socket_path);
                        exit(0);
                    }
                }
            }
        });
    }

    // Accept loop: one client at a time, newest wins.
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };

        let hello = format!(
            "{{\"pid\":{},\"rows\":{},\"cols\":{},\"proto\":2}}",
            shell_pid, config.rows, config.cols
        );
        if write_frame(&mut stream, T_HELLO, hello.as_bytes()).is_err() {
            continue;
        }

        let my_gen = {
            let mut shared = state.shared.lock().unwrap();
            if let Some(old) = shared.client.take() {
                let _ = old.shutdown(std::net::Shutdown::Both);
            }
            // Bytes for the previous client are already folded into the
            // emulator; the new client starts from a repaint it requests.
            shared.ring.clear();
            shared.repaint_pending = 0;
            shared.client = stream.try_clone().ok();
            shared.client_gen += 1;
            state.cond.notify_all();
            shared.client_gen
        };

        // Client -> holder control frames, one thread per connection.
        let state = Arc::clone(&state);
        let pty_writer = Arc::clone(&pty_writer);
        let master = Arc::clone(&master);
        let killer = Arc::clone(&killer);
        thread::spawn(move || {
            loop {
                match read_frame(&mut stream) {
                    Ok((T_INPUT, data)) => {
                        let mut writer = pty_writer.lock().unwrap();
                        if writer.write_all(&data).and_then(|_| writer.flush()).is_err() {
                            break;
                        }
                    }
                    Ok((T_RESIZE, data)) if data.len() == 4 => {
                        let rows = u16::from_be_bytes([data[0], data[1]]);
                        let cols = u16::from_be_bytes([data[2], data[3]]);
                        state.shared.lock().unwrap().screen.resize(rows, cols);
                        let _ = master.lock().unwrap().0.resize(PtySize {
                            rows,
                            cols,
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                    Ok((T_REPAINT_REQ, _)) => {
                        let mut shared = state.shared.lock().unwrap();
                        shared.repaint_pending += 1;
                        state.cond.notify_all();
                    }
                    Ok((T_KILL, _)) => {
                        let _ = killer.lock().unwrap().kill();
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }

            let mut shared = state.shared.lock().unwrap();
            // Only clear if this connection is still the active one.
            if shared.client_gen == my_gen {
                shared.client = None;
            }
        });
    }
}

struct SendMaster(Box<dyn MasterPty>);
unsafe impl Send for SendMaster {}

fn usage() -> ! {
    eprintln!("usage: dala_holder '<config json>'");
    exit(2);
}

fn final_path(socket_path: &std::path::Path) -> PathBuf {
    let mut p = socket_path.as_os_str().to_owned();
    p.push(".final");
    PathBuf::from(p)
}

fn exit_path(socket_path: &std::path::Path) -> PathBuf {
    let mut p = socket_path.as_os_str().to_owned();
    p.push(".exit");
    PathBuf::from(p)
}

fn fatal(socket_path: &std::path::Path, msg: &str) -> ! {
    eprintln!("dala_holder: {msg}");
    let _ = std::fs::remove_file(socket_path);
    exit(1);
}

/// The BEAM ignores SIGCHLD (and that survives exec), which breaks child-exit
/// detection in anything it spawns — restore defaults before doing any work.
fn reset_signals() {
    unsafe {
        libc::signal(libc::SIGCHLD, libc::SIG_DFL);
        libc::signal(libc::SIGHUP, libc::SIG_DFL);
        // Dead-client writes must surface as EPIPE errors, not kill us.
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut());
    }
}

/// Detach from the spawning BEAM: fork (parent exits so dala's spawn returns),
/// new session, stdio to a per-session log next to the socket. Single-threaded
/// at this point, so the fork is safe.
fn daemonize(socket_path: &std::path::Path) {
    unsafe {
        match libc::fork() {
            -1 => {
                eprintln!("dala_holder: fork failed");
                exit(1);
            }
            0 => {}
            _parent => exit(0),
        }
        libc::setsid();

        let mut log = socket_path.as_os_str().to_owned();
        log.push(".log");
        let log = std::ffi::CString::new(log.as_encoded_bytes()).unwrap();
        let fd = libc::open(
            log.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC,
            0o600,
        );
        let devnull = std::ffi::CString::new("/dev/null").unwrap();
        let null_fd = libc::open(devnull.as_ptr(), libc::O_RDONLY);
        if null_fd >= 0 {
            libc::dup2(null_fd, 0);
            libc::close(null_fd);
        }
        if fd >= 0 {
            libc::dup2(fd, 1);
            libc::dup2(fd, 2);
            libc::close(fd);
        }
    }
}

fn write_frame(stream: &mut UnixStream, frame_type: u8, payload: &[u8]) -> std::io::Result<()> {
    let len = (payload.len() + 1) as u32;
    stream.write_all(&len.to_be_bytes())?;
    stream.write_all(&[frame_type])?;
    stream.write_all(payload)?;
    stream.flush()
}

fn read_frame(stream: &mut UnixStream) -> std::io::Result<(u8, Vec<u8>)> {
    let mut header = [0u8; 4];
    stream.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > 16 * 1024 * 1024 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "bad frame"));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload)?;
    let frame_type = payload[0];
    payload.remove(0);
    Ok((frame_type, payload))
}

