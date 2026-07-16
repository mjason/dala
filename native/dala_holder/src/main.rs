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
//!                      0x05 CWD     <utf8 path (from OSC 7)>
//!                      0x06 AGENT   <title 0x1f body>
//!                      0x07 TEXT_SNAPSHOT <json plain-text grid snapshot>
//!   client -> holder:  0x11 INPUT   <raw bytes>
//!                      0x12 RESIZE  <u16 be rows> <u16 be cols>
//!                      0x13 KILL
//!                      0x14 REPAINT_REQ
//!                      0x15 TEXT_SNAPSHOT_REQ <u32 lines> <u32 max bytes>
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
mod watch;

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

/// Hard bounds on PTY/emulator dimensions, mirroring the server's clamp.
/// The emulator allocates rows×cols cells on resize — a stray 65535×65535
/// frame is a multi-GB grid that aborts the process on allocation failure
/// (verified: OOM-killed holder), and the dying holder closes the PTY under
/// the running shell. The holder must survive any frame a buggy client
/// sends, so clamp defensively at the frame boundary.
const MIN_ROWS: u16 = 2;
const MAX_ROWS: u16 = 500;
const MIN_COLS: u16 = 2;
const MAX_COLS: u16 = 1000;

fn clamp_dims(rows: u16, cols: u16) -> (u16, u16) {
    (rows.clamp(MIN_ROWS, MAX_ROWS), cols.clamp(MIN_COLS, MAX_COLS))
}

const T_HELLO: u8 = 0x01;
const T_OUTPUT: u8 = 0x02;
const T_EXIT: u8 = 0x03;
const T_REPAINT: u8 = 0x04;
const T_CWD: u8 = 0x05;
const T_AGENT: u8 = 0x06;
const T_TEXT_SNAPSHOT: u8 = 0x07;
const T_INPUT: u8 = 0x11;
const T_RESIZE: u8 = 0x12;
const T_KILL: u8 = 0x13;
const T_REPAINT_REQ: u8 = 0x14;
const T_TEXT_SNAPSHOT_REQ: u8 = 0x15;

/// Transit-queue cap between the PTY reader and the socket writer. The
/// emulator is the durable history; this only smooths bursts to an attached
/// client, so overflow (a stalled client) just drops oldest-first — the next
/// repaint covers whatever was lost.
const RING_MAX: usize = 1024 * 1024;
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
    /// Repaints requested by the client (each with the requester's column
    /// count, 0 = unknown), served once the ring is drained.
    repaint_pending: VecDeque<u16>,
    /// Machine-readable snapshots requested by the BEAM, each carrying
    /// {logical line limit, UTF-8 byte limit}.
    text_snapshot_pending: VecDeque<(usize, usize)>,
    /// Latest OSC 7 working directory, pending delivery to the client.
    /// Multiplexers (zellij/tmux) pass the inner shell's OSC 7 through, so
    /// this sees the cwd that /proc/<shell>/cwd cannot (their shells live
    /// under a detached server process).
    cwd_report: Option<String>,
    /// Structured agent notifications (OSC 777 warp://cli-agent, OSC 9),
    /// pending delivery as T_AGENT frames: `title \x1f body`.
    agent_reports: VecDeque<Vec<u8>>,
    /// Carry-over so OSC sequences split across reads are still found.
    osc_tail: Vec<u8>,
}

struct State {
    shared: Mutex<Shared>,
    cond: Condvar,
}

fn main() {
    let arg = std::env::args().nth(1).unwrap_or_else(|| usage());
    // Second personality: `dala_holder watch` — the file drawer's
    // recursive filesystem watcher (see watch.rs). Never returns.
    if arg == "watch" {
        watch::run();
    }
    let mut config: Config = serde_json::from_str(&arg).unwrap_or_else(|e| {
        eprintln!("dala_holder: bad config json: {e}");
        exit(2);
    });
    (config.rows, config.cols) = clamp_dims(config.rows, config.cols);

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
            repaint_pending: VecDeque::new(),
            text_snapshot_pending: VecDeque::new(),
            cwd_report: None,
            agent_reports: VecDeque::new(),
            osc_tail: Vec::new(),
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
                        {
                            let mut out = OscOut::default();
                            let mut tail = std::mem::take(&mut shared.osc_tail);
                            scan_osc(&mut tail, &buf[..n], &mut out);
                            shared.osc_tail = tail;
                            if out.cwd.is_some() {
                                shared.cwd_report = out.cwd;
                            }
                            shared.agent_reports.extend(out.agents);
                        }
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
                TextSnapshot(Vec<u8>),
                Cwd(String),
                Agent(Vec<u8>),
                Exit(u32, Vec<u8>, Vec<u8>),
            }

            loop {
                let (job, stream, gen) = {
                    let mut shared = state.shared.lock().unwrap();
                    loop {
                        let attached = shared.client.is_some();
                        let drainable = attached && !shared.ring.is_empty();
                        let repaint =
                            attached && shared.ring.is_empty() && !shared.repaint_pending.is_empty();
                        let text_snapshot = attached
                            && shared.ring.is_empty()
                            && !shared.text_snapshot_pending.is_empty();
                        let cwd = attached && shared.cwd_report.is_some();
                        let agent = attached && !shared.agent_reports.is_empty();
                        let done = shared.exit_status.is_some() && shared.ring.is_empty();
                        if drainable || repaint || text_snapshot || cwd || agent || done {
                            break;
                        }
                        shared = state.cond.wait(shared).unwrap();
                    }

                    let stream = shared.client.as_ref().and_then(|s| s.try_clone().ok());
                    let gen = shared.client_gen;

                    if shared.client.is_some() && !shared.ring.is_empty() {
                        let n = shared.ring.len().min(CHUNK);
                        (Job::Output(shared.ring.drain(..n).collect()), stream, gen)
                    } else if shared.client.is_some() && shared.cwd_report.is_some() {
                        (Job::Cwd(shared.cwd_report.take().unwrap()), stream, gen)
                    } else if shared.client.is_some() && !shared.agent_reports.is_empty() {
                        (Job::Agent(shared.agent_reports.pop_front().unwrap()), stream, gen)
                    } else if shared.client.is_some() && !shared.repaint_pending.is_empty() {
                        let cols = shared.repaint_pending.pop_front().unwrap_or(0);
                        // Soft wraps are only correct when the requester's
                        // width matches the grid; anything else gets hard
                        // line breaks so the layout cannot shear.
                        let soft = cols as usize == shared.screen.columns();
                        (Job::Repaint(shared.screen.repaint(soft)), stream, gen)
                    } else if shared.client.is_some() && !shared.text_snapshot_pending.is_empty() {
                        let (lines, bytes) = shared.text_snapshot_pending.pop_front().unwrap();
                        let snapshot = shared.screen.text_snapshot(lines, bytes);
                        let encoded = serde_json::to_vec(&snapshot).unwrap_or_else(|_| b"{}".to_vec());
                        (Job::TextSnapshot(encoded), stream, gen)
                    } else {
                        let status = shared.exit_status.unwrap_or(0);
                        let snapshot = shared.screen.text_snapshot(0, 64 * 1024);
                        let encoded = serde_json::to_vec(&snapshot).unwrap_or_else(|_| b"{}".to_vec());
                        (Job::Exit(status, shared.screen.repaint(false), encoded), stream, gen)
                    }
                };

                match job {
                    // Undeliverable frames are simply dropped: the emulator
                    // has the bytes, and any future client starts from a
                    // repaint that covers them.
                    Job::Output(chunk) => send_or_drop(&state, stream, gen, T_OUTPUT, &chunk),
                    Job::Cwd(cwd) => send_or_drop(&state, stream, gen, T_CWD, cwd.as_bytes()),
                    Job::Agent(payload) => send_or_drop(&state, stream, gen, T_AGENT, &payload),
                    Job::Repaint(repaint) => send_or_drop(&state, stream, gen, T_REPAINT, &repaint),
                    Job::TextSnapshot(snapshot) => {
                        send_or_drop(&state, stream, gen, T_TEXT_SNAPSHOT, &snapshot)
                    }
                    Job::Exit(status, final_screen, final_text) => {
                        // Durable first: a dala that is down right now finds the
                        // status and the last screen on reattach.
                        let _ = std::fs::write(exit_path(&socket_path), status.to_string());
                        let _ = std::fs::write(final_path(&socket_path), &final_screen);
                        let _ = std::fs::write(text_final_path(&socket_path), &final_text);
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
            "{{\"pid\":{},\"rows\":{},\"cols\":{},\"proto\":3}}",
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
            shared.repaint_pending.clear();
            shared.text_snapshot_pending.clear();
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
                        let (rows, cols) = clamp_dims(rows, cols);
                        state.shared.lock().unwrap().screen.resize(rows, cols);
                        let _ = master.lock().unwrap().0.resize(PtySize {
                            rows,
                            cols,
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                    Ok((T_REPAINT_REQ, data)) => {
                        let cols = if data.len() >= 2 {
                            u16::from_be_bytes([data[0], data[1]])
                        } else {
                            0
                        };
                        let mut shared = state.shared.lock().unwrap();
                        shared.repaint_pending.push_back(cols);
                        state.cond.notify_all();
                    }
                    Ok((T_TEXT_SNAPSHOT_REQ, data)) if data.len() == 8 => {
                        let lines = u32::from_be_bytes(data[0..4].try_into().unwrap()) as usize;
                        let bytes = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
                        let lines = lines.min(50_000);
                        let bytes = bytes.clamp(1, 128 * 1024);
                        let mut shared = state.shared.lock().unwrap();
                        shared.text_snapshot_pending.push_back((lines, bytes));
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

/// Finds OSC 7 (`ESC ] 7 ; file://host/path BEL|ST`) in the output stream.
/// A small tail is carried between reads so split sequences still match.
/// Parsed results of one scan pass.
#[derive(Default)]
struct OscOut {
    cwd: Option<String>,
    /// `title \x1f body` payloads for T_AGENT frames.
    agents: Vec<Vec<u8>>,
}

/// Scans output for the OSC sequences dala understands:
///   7   — cwd report (`file://host/path`)
///   777 — `notify;<title>;<body>`: desktop notifications; with title
///         `warp://cli-agent` the body is a structured agent event JSON
///         (Warp's open cli-agent protocol, emitted by the agent plugins)
///   9   — plain notification text (e.g. Codex's native notifications)
/// Sequences may split across reads; an unterminated candidate is carried
/// over in `tail` (bounded, so a huge unrelated OSC cannot pin memory).
fn scan_osc(tail: &mut Vec<u8>, chunk: &[u8], out: &mut OscOut) {
    const PREFIX: &[u8] = b"\x1b]";
    const TAIL_KEEP: usize = 8192;

    let mut hay = std::mem::take(tail);
    hay.extend_from_slice(chunk);

    let mut search_from = 0;
    while let Some(start) = find(&hay[search_from..], PREFIX).map(|i| i + search_from) {
        let body_start = start + PREFIX.len();
        // Terminator: BEL or ST (ESC \).
        let end = hay[body_start..]
            .iter()
            .position(|&b| b == 0x07)
            .map(|i| (body_start + i, 1))
            .or_else(|| find(&hay[body_start..], b"\x1b\\").map(|i| (body_start + i, 2)));

        let Some((end, term_len)) = end else {
            // Unterminated: keep from the sequence start for the next read.
            *tail = hay[start..].to_vec();
            tail.truncate(TAIL_KEEP);
            return;
        };

        let body = &hay[body_start..end];
        if let Some(url) = body.strip_prefix(b"7;") {
            if let Ok(url) = std::str::from_utf8(url) {
                if let Some(path) = url.strip_prefix("file://") {
                    let path = match path.find('/') {
                        Some(i) => &path[i..],
                        None => "/",
                    };
                    if let Some(decoded) = percent_decode(path) {
                        out.cwd = Some(decoded);
                    }
                }
            }
        } else if let Some(rest) = body.strip_prefix(b"777;notify;") {
            // rest = <title>;<body> — the body itself may contain ';'.
            if let Some(sep) = rest.iter().position(|&b| b == b';') {
                let mut payload = rest[..sep].to_vec();
                payload.push(0x1f);
                payload.extend_from_slice(&rest[sep + 1..]);
                out.agents.push(payload);
            }
        } else if let Some(text) = body.strip_prefix(b"9;") {
            let mut payload = b"osc9".to_vec();
            payload.push(0x1f);
            payload.extend_from_slice(text);
            out.agents.push(payload);
        }
        search_from = end + term_len;
    }

    // Keep a tail in case a sequence starts at the very end of this chunk.
    let keep = hay.len().saturating_sub(PREFIX.len().max(8));
    *tail = hay[keep.max(search_from.min(hay.len()))..].to_vec();
    tail.truncate(TAIL_KEEP);
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn percent_decode(path: &str) -> Option<String> {
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

struct SendMaster(Box<dyn MasterPty>);
unsafe impl Send for SendMaster {}

fn usage() -> ! {
    eprintln!("usage: dala_holder '<config json>' | dala_holder watch");
    exit(2);
}

fn final_path(socket_path: &std::path::Path) -> PathBuf {
    let mut p = socket_path.as_os_str().to_owned();
    p.push(".final");
    PathBuf::from(p)
}

fn text_final_path(socket_path: &std::path::Path) -> PathBuf {
    let mut p = socket_path.as_os_str().to_owned();
    p.push(".text");
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

/// Writes one frame to the (possibly already replaced) client; on failure,
/// detaches the client — but only if it is still the same connection
/// generation, so a newer client is never clobbered by a stale write.
fn send_or_drop(state: &State, stream: Option<UnixStream>, gen: u64, frame_type: u8, payload: &[u8]) {
    if let Some(mut stream) = stream {
        if write_frame(&mut stream, frame_type, payload).is_err() {
            let mut shared = state.shared.lock().unwrap();
            if shared.client_gen == gen {
                shared.client = None;
            }
        }
    }
}

fn write_frame(stream: &mut impl Write, frame_type: u8, payload: &[u8]) -> std::io::Result<()> {
    let len = (payload.len() + 1) as u32;
    stream.write_all(&len.to_be_bytes())?;
    stream.write_all(&[frame_type])?;
    stream.write_all(payload)?;
    stream.flush()
}

fn read_frame(stream: &mut impl Read) -> std::io::Result<(u8, Vec<u8>)> {
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


#[cfg(test)]
mod frame_tests {
    use super::*;
    use std::io::Cursor;

    /// Serializes a frame into a byte buffer.
    fn framed(frame_type: u8, payload: &[u8]) -> Vec<u8> {
        let mut buf = Vec::new();
        write_frame(&mut buf, frame_type, payload).unwrap();
        buf
    }

    #[test]
    fn wire_format_is_len_prefix_type_tag_payload() {
        let buf = framed(T_OUTPUT, b"hi");
        // 4-byte BE length (payload + 1 type byte), then tag, then payload.
        assert_eq!(buf, [0, 0, 0, 3, T_OUTPUT, b'h', b'i']);
    }

    #[test]
    fn round_trips_normal_frame() {
        let buf = framed(T_INPUT, b"echo hello\n");
        let (ty, payload) = read_frame(&mut Cursor::new(buf)).unwrap();
        assert_eq!(ty, T_INPUT);
        assert_eq!(payload, b"echo hello\n");
    }

    #[test]
    fn round_trips_empty_payload() {
        let buf = framed(T_KILL, b"");
        assert_eq!(buf, [0, 0, 0, 1, T_KILL]);
        let (ty, payload) = read_frame(&mut Cursor::new(buf)).unwrap();
        assert_eq!(ty, T_KILL);
        assert!(payload.is_empty());
    }

    #[test]
    fn round_trips_every_frame_type_byte_exact() {
        let types = [
            T_HELLO, T_OUTPUT, T_EXIT, T_REPAINT, T_CWD, T_AGENT, T_INPUT, T_RESIZE, T_KILL,
            T_TEXT_SNAPSHOT, T_REPAINT_REQ, T_TEXT_SNAPSHOT_REQ,
        ];
        for &ty in &types {
            // Payload exercises all byte values including 0x00 and 0xff.
            let payload: Vec<u8> = (0..=255u8).collect();
            let buf = framed(ty, &payload);
            let (got_ty, got_payload) = read_frame(&mut Cursor::new(buf)).unwrap();
            assert_eq!(got_ty, ty);
            assert_eq!(got_payload, payload);
        }
    }

    #[test]
    fn rejects_zero_length_frame() {
        let buf = vec![0u8, 0, 0, 0];
        let err = read_frame(&mut Cursor::new(buf)).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn rejects_oversized_frame() {
        // Declared length just over the 16 MiB cap; no payload needed —
        // the cap check happens before any payload read.
        let len = (16 * 1024 * 1024 + 1) as u32;
        let buf = len.to_be_bytes().to_vec();
        let err = read_frame(&mut Cursor::new(buf)).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn accepts_frame_at_exact_size_cap() {
        let payload = vec![0xabu8; 16 * 1024 * 1024 - 1];
        let buf = framed(T_OUTPUT, &payload);
        let (ty, got) = read_frame(&mut Cursor::new(buf)).unwrap();
        assert_eq!(ty, T_OUTPUT);
        assert_eq!(got, payload);
    }

    #[test]
    fn truncated_header_is_err() {
        let buf = vec![0u8, 0, 0]; // only 3 of 4 header bytes
        assert!(read_frame(&mut Cursor::new(buf)).is_err());
    }

    #[test]
    fn truncated_payload_is_err() {
        let mut buf = framed(T_OUTPUT, b"full payload");
        buf.truncate(buf.len() - 3);
        assert!(read_frame(&mut Cursor::new(buf)).is_err());
    }

    #[test]
    fn reads_consecutive_frames_from_one_stream() {
        let mut buf = framed(T_CWD, b"/tmp");
        buf.extend(framed(T_EXIT, &7u32.to_be_bytes()));
        let mut cur = Cursor::new(buf);
        let (t1, p1) = read_frame(&mut cur).unwrap();
        let (t2, p2) = read_frame(&mut cur).unwrap();
        assert_eq!((t1, p1.as_slice()), (T_CWD, b"/tmp".as_slice()));
        assert_eq!(t2, T_EXIT);
        assert_eq!(u32::from_be_bytes(p2.try_into().unwrap()), 7);
    }
}

#[cfg(test)]
mod clamp_dims_tests {
    use super::*;

    #[test]
    fn passes_normal_dims_through() {
        assert_eq!(clamp_dims(24, 80), (24, 80));
        assert_eq!(clamp_dims(50, 220), (50, 220));
        assert_eq!(clamp_dims(MAX_ROWS, MAX_COLS), (MAX_ROWS, MAX_COLS));
    }

    #[test]
    fn zero_and_one_are_raised_to_the_floor() {
        assert_eq!(clamp_dims(0, 0), (MIN_ROWS, MIN_COLS));
        assert_eq!(clamp_dims(1, 1), (MIN_ROWS, MIN_COLS));
        assert_eq!(clamp_dims(0, 80), (MIN_ROWS, 80));
        assert_eq!(clamp_dims(24, 0), (24, MIN_COLS));
    }

    #[test]
    fn huge_dims_are_capped_before_they_reach_the_grid_allocator() {
        // 65535×65535 would be a multi-GB cell grid — the exact frame that
        // OOM-killed the holder (and hung up the PTY) before the clamp.
        assert_eq!(clamp_dims(u16::MAX, u16::MAX), (MAX_ROWS, MAX_COLS));
        assert_eq!(clamp_dims(501, 1001), (MAX_ROWS, MAX_COLS));
    }

    #[test]
    fn clamped_resize_is_survivable_end_to_end() {
        // The emulator itself must take the full clamped range in stride,
        // including rapid alternation (ownership ping-pong).
        let mut screen = crate::screen::Screen::new(24, 80, 100);
        for _ in 0..5 {
            let (r, c) = clamp_dims(u16::MAX, u16::MAX);
            screen.resize(r, c);
            screen.advance(b"after huge\r\n");
            let (r, c) = clamp_dims(0, 0);
            screen.resize(r, c);
            screen.advance(b"after tiny\r\n");
        }
        let (r, c) = clamp_dims(40, 160);
        screen.resize(r, c);
        screen.advance(b"settled");
        let out = String::from_utf8_lossy(&screen.repaint(true)).into_owned();
        assert!(out.contains("settled"));
    }
}

#[cfg(test)]
mod percent_decode_tests {
    use super::*;

    #[test]
    fn decodes_escaped_slash() {
        assert_eq!(percent_decode("%2Ftmp%2Fx").as_deref(), Some("/tmp/x"));
    }

    #[test]
    fn passes_literal_text_through() {
        assert_eq!(
            percent_decode("/home/mj/dev").as_deref(),
            Some("/home/mj/dev")
        );
    }

    #[test]
    fn decodes_mixed_case_hex_and_spaces() {
        assert_eq!(
            percent_decode("/a%20b/%C3%A9").as_deref(),
            Some("/a b/é")
        );
    }

    #[test]
    fn truncated_escape_at_end_is_literal() {
        // "%2" at end: not enough bytes to decode, kept verbatim.
        assert_eq!(percent_decode("/tmp/x%2").as_deref(), Some("/tmp/x%2"));
        assert_eq!(percent_decode("/tmp/x%").as_deref(), Some("/tmp/x%"));
    }

    #[test]
    fn invalid_hex_pair_is_none() {
        assert_eq!(percent_decode("/tmp/%zz/x"), None);
    }

    #[test]
    fn double_percent_before_hex_is_none() {
        // "%%4" parses "%4" as the hex pair, which is invalid.
        assert_eq!(percent_decode("%%41"), None);
    }

    #[test]
    fn bare_double_percent_at_end_is_literal() {
        assert_eq!(percent_decode("/x%%").as_deref(), Some("/x%%"));
    }

    #[test]
    fn invalid_utf8_after_decode_is_none() {
        assert_eq!(percent_decode("/x%FF/y"), None);
    }
}

#[cfg(test)]
mod config_tests {
    use super::*;

    #[test]
    fn minimal_config_gets_defaults() {
        let json = r#"{"socket":"/tmp/h.sock","shell":"/bin/zsh","rows":24,"cols":80}"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert_eq!(config.socket, "/tmp/h.sock");
        assert_eq!(config.shell, "/bin/zsh");
        assert_eq!(config.rows, 24);
        assert_eq!(config.cols, 80);
        assert!(config.args.is_empty());
        assert_eq!(config.cwd, "");
        assert!(config.env.is_empty());
        assert!(config.env_remove.is_empty());
        assert_eq!(config.history_lines, 10_000);
    }

    #[test]
    fn full_config_parses() {
        let json = r#"{
            "socket": "/run/dala/s1.sock",
            "shell": "/usr/bin/fish",
            "args": ["-l", "-i"],
            "cwd": "/home/mj",
            "env": [["TERM", "xterm-256color"], ["LANG", "en_US.UTF-8"]],
            "env_remove": ["CLAUDECODE"],
            "rows": 50,
            "cols": 120,
            "history_lines": 5000
        }"#;
        let config: Config = serde_json::from_str(json).unwrap();
        assert_eq!(config.socket, "/run/dala/s1.sock");
        assert_eq!(config.shell, "/usr/bin/fish");
        assert_eq!(config.args, vec!["-l", "-i"]);
        assert_eq!(config.cwd, "/home/mj");
        assert_eq!(
            config.env,
            vec![
                ("TERM".to_string(), "xterm-256color".to_string()),
                ("LANG".to_string(), "en_US.UTF-8".to_string()),
            ]
        );
        assert_eq!(config.env_remove, vec!["CLAUDECODE"]);
        assert_eq!(config.rows, 50);
        assert_eq!(config.cols, 120);
        assert_eq!(config.history_lines, 5000);
    }

    #[test]
    fn missing_required_field_is_err() {
        let json = r#"{"socket":"/tmp/h.sock","rows":24,"cols":80}"#;
        assert!(serde_json::from_str::<Config>(json).is_err());
    }
}

#[cfg(test)]
mod scan_tests {
    use super::*;

    fn run(chunks: &[&[u8]]) -> (Option<String>, Vec<Vec<u8>>) {
        let mut tail = Vec::new();
        let mut out = OscOut::default();
        for c in chunks {
            scan_osc(&mut tail, c, &mut out);
        }
        (out.cwd, out.agents)
    }

    #[test]
    fn parses_osc7_cwd() {
        let (cwd, _) = run(&[b"junk\x1b]7;file://host/tmp/x\x07more"]);
        assert_eq!(cwd.as_deref(), Some("/tmp/x"));
    }

    #[test]
    fn parses_osc777_agent_event() {
        let (_, agents) = run(&[b"\x1b]777;notify;warp://cli-agent;{\"event\":\"stop\"}\x07"]);
        assert_eq!(agents.len(), 1);
        assert_eq!(
            agents[0],
            b"warp://cli-agent\x1f{\"event\":\"stop\"}".to_vec()
        );
    }

    #[test]
    fn parses_osc9_plain_notification() {
        let (_, agents) = run(&[b"\x1b]9;task finished\x1b\\"]);
        assert_eq!(agents[0], b"osc9\x1ftask finished".to_vec());
    }

    #[test]
    fn survives_split_across_reads() {
        let (_, agents) = run(&[b"\x1b]777;noti", b"fy;warp://cli-agent;{}", b"\x07"]);
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0], b"warp://cli-agent\x1f{}".to_vec());
    }

    #[test]
    fn body_may_contain_semicolons() {
        let (_, agents) = run(&[b"\x1b]777;notify;t;a;b;c\x07"]);
        assert_eq!(agents[0], b"t\x1fa;b;c".to_vec());
    }
}
