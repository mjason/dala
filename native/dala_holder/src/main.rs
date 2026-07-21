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
//!                      0x07 TEXT_SNAPSHOT <json text + TUI style snapshot>
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
//! Ordering: a repaint fixes an output-position barrier and briefly freezes
//! PTY ingestion. OUTPUT through that barrier is sent first, then a fresh
//! parser-safe repaint; ingestion resumes only after the frame is written.
//! This keeps snapshots sequence-correct without letting continuous output
//! starve or overtake them.
//!
//! One client at a time; a new connection kicks the old one. The emulator
//! retains output while detached; the bounded live ring exists only for the
//! attached client, whose reconnect starts from a synthesized repaint. When
//! the shell exits the holder writes `{socket}.exit` with the status (for a
//! dala that reconnects later), best-effort sends EXIT, unlinks the socket
//! and exits.

mod screen;
mod watch;

use std::collections::VecDeque;
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::exit;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

#[cfg(windows)]
use std::net::{TcpListener, TcpStream};

#[cfg(unix)]
type LocalListener = UnixListener;
#[cfg(unix)]
type LocalStream = UnixStream;
#[cfg(windows)]
type LocalListener = TcpListener;
#[cfg(windows)]
type LocalStream = TcpStream;

use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};

use crate::screen::{Screen, REPAINT_HISTORY_BUDGET};

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
    (
        rows.clamp(MIN_ROWS, MAX_ROWS),
        cols.clamp(MIN_COLS, MAX_COLS),
    )
}

const T_HELLO: u8 = 0x01;
const T_OUTPUT: u8 = 0x02;
const T_EXIT: u8 = 0x03;
const T_REPAINT: u8 = 0x04;
const T_CWD: u8 = 0x05;
const T_AGENT: u8 = 0x06;
const T_TEXT_SNAPSHOT: u8 = 0x07;
const T_PROCESSES: u8 = 0x08;
const T_AUTH: u8 = 0x10;
const T_INPUT: u8 = 0x11;
const T_RESIZE: u8 = 0x12;
const T_KILL: u8 = 0x13;
const T_REPAINT_REQ: u8 = 0x14;
const T_TEXT_SNAPSHOT_REQ: u8 = 0x15;
const T_PROCESSES_REQ: u8 = 0x16;

/// Transit-queue cap between the PTY reader and the socket writer. The
/// emulator is the durable history; this only smooths bursts to an attached
/// client, so overflow (a stalled client) just drops oldest-first — the next
/// repaint covers whatever was lost.
const RING_MAX: usize = 1024 * 1024;
const CHUNK: usize = 64 * 1024;
// A stalled local client must not hold the sole socket writer forever. In
// particular, repaint keeps PTY ingestion frozen until its frame is written;
// this timeout fails that write and detaches the client before the BEAM's
// four-second repaint timeout fires.
const CLIENT_WRITE_TIMEOUT: Duration = Duration::from_secs(2);
// A well-behaved channel has at most one in-flight repaint. Leave room for
// many attached clients, but bound work queued by a malformed/raw peer. New
// requests are rejected at the limit so holder replies stay FIFO-aligned with
// the BEAM's pending-request queue.
const MAX_PENDING_REPAINTS: usize = 64;
// TEXT_SNAPSHOT has no request id on the wire. Never evict or silently reject
// an individual request: doing so would make every later response satisfy the
// wrong BEAM caller. The control connection is detached on the first request
// beyond this bound, clearing all pending requests together.
const MAX_PENDING_TEXT_SNAPSHOTS: usize = 64;
// Agent notifications are best-effort UI events. Keep the newest bounded tail
// when a process emits them faster than the client can consume them.
const MAX_AGENT_REPORTS: usize = 256;
// Match alacritty's synchronized-update safety scale. An unterminated OSC/DCS
// from a broken process must not grow one holder without bound; CAN is a valid
// terminal cancellation byte and returns both parsers to ground safely.
const PARSER_TOKEN_MAX: usize = 2 * 1024 * 1024;

#[derive(Deserialize, Serialize)]
struct Config {
    socket: String,
    #[serde(default)]
    token: String,
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

#[derive(Deserialize)]
struct ExecConfig {
    command: Vec<String>,
    stderr: String,
}

#[derive(Serialize)]
struct ProcessInfo {
    pid: u32,
    parent_pid: Option<u32>,
    executable: String,
    argv: Vec<String>,
}

fn default_history_lines() -> usize {
    10_000
}

#[derive(Default)]
struct TransitQueue {
    /// Every chunk starts and ends with the terminal parser in ground state.
    /// Keeping those boundaries through eviction and socket writes ensures a
    /// bounded-ring overflow can never expose the suffix of an ANSI token or
    /// UTF-8 codepoint to the browser.
    chunks: VecDeque<Vec<u8>>,
    len: usize,
    /// Absolute position of the first byte still queued. Bytes dequeued for an
    /// in-flight socket write already count as passed: the sole writer cannot
    /// select the following repaint until that write returns.
    start: u64,
    /// Absolute position immediately after the newest byte ever queued.
    end: u64,
}

impl TransitQueue {
    fn push_bounded(&mut self, data: &[u8], limit: usize) -> usize {
        if data.is_empty() {
            return 0;
        }

        self.chunks.push_back(data.to_vec());
        self.len = self.len.saturating_add(data.len());
        self.end = self.end.saturating_add(data.len() as u64);

        let mut dropped = 0usize;
        while self.len > limit {
            let Some(chunk) = self.chunks.pop_front() else {
                break;
            };
            self.len -= chunk.len();
            dropped = dropped.saturating_add(chunk.len());
            self.start = self.start.saturating_add(chunk.len() as u64);
        }

        dropped
    }

    fn end_position(&self) -> u64 {
        self.end
    }

    fn reached(&self, barrier: u64) -> bool {
        self.start >= barrier
    }

    fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    /// Drain only output that existed at `barrier`. Newer bytes remain queued
    /// until the associated repaint has been sent.
    fn drain_before(&mut self, barrier: Option<u64>, max: usize) -> Vec<u8> {
        let allowed_end = barrier.unwrap_or(self.end);
        let mut output = Vec::new();

        while let Some(chunk) = self.chunks.front() {
            let chunk_end = self.start.saturating_add(chunk.len() as u64);
            if chunk_end > allowed_end {
                break;
            }

            // Never split a parser-safe chunk. A single chunk can exceed the
            // preferred frame size only for a long control string; taking it
            // whole is required to return the browser parser to ground.
            if !output.is_empty() && output.len().saturating_add(chunk.len()) > max {
                break;
            }

            let chunk = self.chunks.pop_front().unwrap();
            self.len -= chunk.len();
            self.start = self.start.saturating_add(chunk.len() as u64);
            output.extend_from_slice(&chunk);
        }

        output
    }

    fn clear(&mut self) {
        self.chunks.clear();
        self.len = 0;
        self.start = self.end;
    }
}

/// Buffers only the unfinished tail of the terminal byte stream. A repaint
/// starts with RIS (`ESC c`), which resets the browser parser; putting that
/// reset between `ESC [` and its CSI final byte (or inside a UTF-8 codepoint)
/// would turn the suffix into visible garbage. Feeding the emulator and live
/// transit queue only at parser-ground boundaries makes every repaint barrier
/// safe without delaying ordinary text.
#[derive(Default)]
struct ParserSafeOutput {
    pending: Vec<u8>,
    safe_len: usize,
    state: BoundaryState,
}

#[derive(Clone, Copy, Default)]
enum BoundaryState {
    #[default]
    Ground,
    Utf8(u8),
    Escape,
    EscapeIntermediate,
    Csi,
    Osc,
    Dcs,
    ControlString,
    StringEscape,
}

impl ParserSafeOutput {
    fn push(&mut self, bytes: &[u8]) -> Vec<u8> {
        for &byte in bytes {
            self.pending.push(byte);
            self.advance(byte);
            if matches!(self.state, BoundaryState::Ground) {
                self.safe_len = self.pending.len();
            } else if self.pending.len() >= PARSER_TOKEN_MAX && self.safe_len == 0 {
                self.pending.push(0x18);
                self.advance(0x18);
                self.safe_len = self.pending.len();
            }
        }

        if self.safe_len == 0 {
            return Vec::new();
        }

        let tail = self.pending.split_off(self.safe_len);
        let complete = std::mem::replace(&mut self.pending, tail);
        self.safe_len = 0;
        complete
    }

    fn advance(&mut self, byte: u8) {
        let mut current = Some(byte);
        while let Some(byte) = current.take() {
            self.state = match self.state {
                BoundaryState::Ground => match byte {
                    0x1b => BoundaryState::Escape,
                    // C1 control functions are valid 8-bit counterparts of
                    // the 7-bit ESC-prefixed forms. They are recognized only
                    // in ground state; bytes consumed by Utf8 below are
                    // continuation bytes, never new control introducers.
                    0x90 => BoundaryState::Dcs,
                    0x98 | 0x9e | 0x9f => BoundaryState::ControlString,
                    0x9b => BoundaryState::Csi,
                    0x9d => BoundaryState::Osc,
                    0xc2..=0xdf => BoundaryState::Utf8(1),
                    0xe0..=0xef => BoundaryState::Utf8(2),
                    0xf0..=0xf4 => BoundaryState::Utf8(3),
                    _ => BoundaryState::Ground,
                },
                BoundaryState::Utf8(remaining) => {
                    if (0x80..=0xbf).contains(&byte) {
                        if remaining == 1 {
                            BoundaryState::Ground
                        } else {
                            BoundaryState::Utf8(remaining - 1)
                        }
                    } else {
                        // The VTE parser consumes an invalid partial codepoint
                        // as a replacement character, then treats this byte as
                        // the beginning of the next token.
                        current = Some(byte);
                        BoundaryState::Ground
                    }
                }
                BoundaryState::Escape => match byte {
                    b'[' => BoundaryState::Csi,
                    b']' => BoundaryState::Osc,
                    b'P' => BoundaryState::Dcs,
                    b'X' | b'^' | b'_' => BoundaryState::ControlString,
                    0x20..=0x2f => BoundaryState::EscapeIntermediate,
                    0x30..=0x7e | 0x18 | 0x1a => BoundaryState::Ground,
                    0x1b => BoundaryState::Escape,
                    _ => BoundaryState::Escape,
                },
                BoundaryState::EscapeIntermediate => match byte {
                    0x30..=0x7e | 0x18 | 0x1a => BoundaryState::Ground,
                    0x1b => BoundaryState::Escape,
                    _ => BoundaryState::EscapeIntermediate,
                },
                BoundaryState::Csi => match byte {
                    0x40..=0x7e | 0x18 | 0x1a => BoundaryState::Ground,
                    0x1b => BoundaryState::Escape,
                    _ => BoundaryState::Csi,
                },
                BoundaryState::Osc => match byte {
                    0x07 | 0x18 | 0x1a | 0x9c => BoundaryState::Ground,
                    0x1b => BoundaryState::StringEscape,
                    _ => BoundaryState::Osc,
                },
                BoundaryState::Dcs => match byte {
                    0x18 | 0x1a | 0x9c => BoundaryState::Ground,
                    0x1b => BoundaryState::StringEscape,
                    _ => BoundaryState::Dcs,
                },
                BoundaryState::ControlString => match byte {
                    0x18 | 0x1a | 0x9c => BoundaryState::Ground,
                    0x1b => BoundaryState::StringEscape,
                    _ => BoundaryState::ControlString,
                },
                BoundaryState::StringEscape => {
                    // ESC already ended OSC/DCS/SOS in vte and put the
                    // parser in Escape; process this same byte as the escape
                    // final/intermediate rather than deferring it.
                    current = Some(byte);
                    BoundaryState::Escape
                }
            };
        }
    }
}

struct PendingRepaint {
    barrier: u64,
    cols: u16,
    history_budget: usize,
}

impl PendingRepaint {
    fn new(transit: &TransitQueue, cols: u16, history_budget: usize) -> Self {
        Self {
            barrier: transit.end_position(),
            cols,
            history_budget,
        }
    }
}

fn enqueue_repaint_bounded(
    pending: &mut VecDeque<PendingRepaint>,
    repaint: PendingRepaint,
) -> bool {
    if pending.len() >= MAX_PENDING_REPAINTS {
        return false;
    }

    pending.push_back(repaint);
    true
}

fn enqueue_text_snapshot_bounded(
    pending: &mut VecDeque<(usize, usize)>,
    request: (usize, usize),
) -> bool {
    if pending.len() >= MAX_PENDING_TEXT_SNAPSHOTS {
        return false;
    }

    pending.push_back(request);
    true
}

fn extend_agent_reports_bounded(
    pending: &mut VecDeque<Vec<u8>>,
    reports: impl IntoIterator<Item = Vec<u8>>,
) {
    for report in reports {
        while pending.len() >= MAX_AGENT_REPORTS {
            pending.pop_front();
        }
        pending.push_back(report);
    }
}

/// The caller serializes writes with the PTY-writer mutex before entering
/// here. Generation validation is intentionally released before the possibly
/// blocking syscall: a frame that won the check may finish, while a handoff
/// can immediately invalidate every writer still waiting behind it.
fn write_input_if_current<W: Write + ?Sized>(
    input_generation: &Mutex<u64>,
    expected_generation: u64,
    writer: &mut W,
    data: &[u8],
) -> std::io::Result<bool> {
    let current = input_generation.lock().unwrap();
    if *current != expected_generation {
        return Ok(false);
    }
    drop(current);

    writer.write_all(data)?;
    writer.flush()?;
    Ok(true)
}

struct Shared {
    transit: TransitQueue,
    client: Option<LocalStream>,
    /// Bumped per accepted connection so stale threads/writes can tell they
    /// lost the client race and must not clear a newer connection.
    client_gen: u64,
    exit_status: Option<u32>,
    pty_done: bool,
    /// Server-side emulator: grid + scrollback + modes.
    screen: Screen,
    /// Repaint requests, each held behind the exact output position that was
    /// current when it arrived. Payloads are synthesized only when dequeued.
    repaint_pending: VecDeque<PendingRepaint>,
    /// PTY output is paused from request until the repaint frame has been
    /// written. This bounds the barrier and prevents post-snapshot ring
    /// overflow while a large repaint is in flight.
    repaint_frozen: bool,
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
    process_reports: VecDeque<Vec<u8>>,
    /// Carry-over so OSC sequences split across reads are still found.
    osc_tail: Vec<u8>,
}

struct State {
    /// Serializes connection handoff against a frame already read by the old
    /// control thread. It is deliberately separate from `shared`: a large PTY
    /// input write may backpressure, but must not block output/repaint state.
    input_generation: Mutex<u64>,
    shared: Mutex<Shared>,
    cond: Condvar,
}

#[derive(Debug, PartialEq, Eq)]
enum TextSnapshotRequestResult {
    Queued,
    Stale,
    Overloaded,
}

fn queue_text_snapshot_request(
    state: &State,
    expected_gen: u64,
    request: (usize, usize),
) -> TextSnapshotRequestResult {
    let result = {
        let mut shared = state.shared.lock().unwrap();
        if shared.client_gen != expected_gen {
            TextSnapshotRequestResult::Stale
        } else if enqueue_text_snapshot_bounded(&mut shared.text_snapshot_pending, request) {
            state.cond.notify_all();
            TextSnapshotRequestResult::Queued
        } else {
            TextSnapshotRequestResult::Overloaded
        }
    };

    if result == TextSnapshotRequestResult::Overloaded {
        detach_client_if_current(state, expected_gen);
    }

    result
}

fn main() {
    let arg = std::env::args().nth(1).unwrap_or_else(|| usage());
    if arg == "exec" {
        let config = std::env::args().nth(2).unwrap_or_else(|| usage());
        run_exec_proxy(&config);
    }
    // Second personality: `dala_holder watch` — the file drawer's
    // recursive filesystem watcher (see watch.rs). Never returns.
    if arg == "watch" {
        watch::run();
    }

    #[cfg(windows)]
    if arg == "--holder-config" {
        let path = std::env::args().nth(2).unwrap_or_else(|| usage());
        let config = std::fs::read_to_string(&path).unwrap_or_else(|e| {
            eprintln!("dala_holder: read launch config {path}: {e}");
            exit(2);
        });
        let _ = std::fs::remove_file(&path);
        run_holder(&config);
        exit(0);
    }

    #[cfg(windows)]
    spawn_windows_child(&arg);

    #[cfg(not(windows))]
    run_holder(&arg);
}

fn run_holder(arg: &str) {
    let mut config: Config = serde_json::from_str(arg).unwrap_or_else(|e| {
        eprintln!("dala_holder: bad config json: {e}");
        exit(2);
    });
    (config.rows, config.cols) = clamp_dims(config.rows, config.cols);

    reset_signals();

    let socket_path = PathBuf::from(&config.socket);
    if let Some(dir) = socket_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _session_lock = acquire_session_lock(&socket_path).unwrap_or_else(|e| {
        eprintln!("dala_holder: lock {}: {e}", socket_path.display());
        exit(3);
    });
    // A live holder for this session means we must not double-spawn; a stale
    // socket is the spawner's job to clear before launching us.
    let listener = match bind_local(&socket_path, &config.token) {
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
    let pty_writer = Arc::new(Mutex::new(Some(pty_writer)));
    // Kept for resize; unix PTY masters are fd wrappers, access is serialized.
    let master: Arc<Mutex<Option<SendMaster>>> =
        Arc::new(Mutex::new(Some(SendMaster(pair.master))));

    let state = Arc::new(State {
        input_generation: Mutex::new(0),
        shared: Mutex::new(Shared {
            transit: TransitQueue::default(),
            client: None,
            client_gen: 0,
            exit_status: None,
            pty_done: false,
            screen: Screen::new(config.rows, config.cols, config.history_lines),
            repaint_pending: VecDeque::new(),
            repaint_frozen: false,
            text_snapshot_pending: VecDeque::new(),
            cwd_report: None,
            agent_reports: VecDeque::new(),
            process_reports: VecDeque::new(),
            osc_tail: Vec::new(),
        }),
        cond: Condvar::new(),
    });

    // Wait independently from the output reader. ConPTY keeps its output pipe
    // open until the pseudoconsole handles are dropped, so waiting for reader
    // EOF before child.wait() deadlocks on Windows.
    {
        let state = Arc::clone(&state);
        let pty_writer = Arc::clone(&pty_writer);
        let master = Arc::clone(&master);
        thread::spawn(move || {
            let status = child.wait().map(|s| s.exit_code()).unwrap_or(0);
            pty_writer.lock().unwrap().take();
            master.lock().unwrap().take();
            let mut shared = state.shared.lock().unwrap();
            shared.exit_status = Some(status);
            state.cond.notify_all();
        });
    }

    // PTY -> ring.
    {
        let state = Arc::clone(&state);
        let pty_writer = Arc::clone(&pty_writer);
        thread::spawn(move || {
            let mut buf = [0u8; 16384];
            let mut parser_safe_output = ParserSafeOutput::default();
            loop {
                match pty_reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let complete = parser_safe_output.push(&buf[..n]);
                        if complete.is_empty() {
                            continue;
                        }

                        let mut shared = state.shared.lock().unwrap();
                        // A requested repaint freezes the emulator at its
                        // parser-safe barrier. Bytes already read from the PTY
                        // stay in this thread until the snapshot frame is on
                        // the socket, applying natural PTY backpressure.
                        while shared.repaint_frozen {
                            shared = state.cond.wait(shared).unwrap();
                        }

                        shared.screen.advance(&complete);
                        let pty_replies = shared.screen.take_pty_writes();
                        {
                            let mut out = OscOut::default();
                            let mut tail = std::mem::take(&mut shared.osc_tail);
                            scan_osc(&mut tail, &complete, &mut out);
                            shared.osc_tail = tail;
                            if out.cwd.is_some() {
                                shared.cwd_report = out.cwd;
                            }
                            extend_agent_reports_bounded(&mut shared.agent_reports, out.agents);
                        }
                        // The emulator is the durable history; the ring only
                        // carries live bytes to the attached client.
                        if shared.client.is_some() {
                            shared.transit.push_bounded(&complete, RING_MAX);
                        }
                        state.cond.notify_all();
                        drop(shared);

                        if !pty_replies.is_empty() {
                            let mut writer = pty_writer.lock().unwrap();
                            if let Some(writer) = writer.as_mut() {
                                for reply in pty_replies {
                                    if writer.write_all(&reply).is_err() {
                                        break;
                                    }
                                }
                                let _ = writer.flush();
                            }
                        }
                    }
                    // EIO once the child side is gone.
                    Err(_) => break,
                }
            }

            let mut shared = state.shared.lock().unwrap();
            shared.pty_done = true;
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
                Processes(Vec<u8>),
                Exit(u32, Vec<u8>, Vec<u8>),
            }

            loop {
                let (job, stream, gen) = {
                    let mut shared = state.shared.lock().unwrap();
                    loop {
                        let attached = shared.client.is_some();
                        let barrier = shared
                            .repaint_pending
                            .front()
                            .map(|pending| pending.barrier);
                        let repaint = attached
                            && barrier.is_some_and(|position| shared.transit.reached(position));
                        let drainable = attached
                            && !shared.transit.is_empty()
                            && barrier.is_none_or(|position| !shared.transit.reached(position));
                        let text_snapshot = attached
                            && shared.transit.is_empty()
                            && !shared.text_snapshot_pending.is_empty();
                        let cwd = attached && shared.cwd_report.is_some();
                        let agent = attached && !shared.agent_reports.is_empty();
                        let processes = attached && !shared.process_reports.is_empty();
                        let done = shared.exit_status.is_some()
                            && shared.pty_done
                            && shared.transit.is_empty();
                        if drainable
                            || repaint
                            || text_snapshot
                            || cwd
                            || agent
                            || processes
                            || done
                        {
                            break;
                        }
                        shared = state.cond.wait(shared).unwrap();
                    }

                    let stream = shared.client.as_ref().and_then(|s| s.try_clone().ok());
                    let gen = shared.client_gen;

                    let barrier = shared
                        .repaint_pending
                        .front()
                        .map(|pending| pending.barrier);

                    if shared.client.is_some()
                        && !shared.transit.is_empty()
                        && barrier.is_none_or(|position| !shared.transit.reached(position))
                    {
                        (
                            Job::Output(shared.transit.drain_before(barrier, CHUNK)),
                            stream,
                            gen,
                        )
                    } else if shared.client.is_some()
                        && barrier.is_some_and(|position| shared.transit.reached(position))
                    {
                        let pending = shared.repaint_pending.pop_front().unwrap();
                        let soft = pending.cols as usize == shared.screen.columns();
                        let repaint = shared
                            .screen
                            .repaint_with_history(soft, pending.history_budget);
                        (Job::Repaint(repaint), stream, gen)
                    } else if shared.client.is_some() && shared.cwd_report.is_some() {
                        (Job::Cwd(shared.cwd_report.take().unwrap()), stream, gen)
                    } else if shared.client.is_some() && !shared.agent_reports.is_empty() {
                        (
                            Job::Agent(shared.agent_reports.pop_front().unwrap()),
                            stream,
                            gen,
                        )
                    } else if shared.client.is_some() && !shared.process_reports.is_empty() {
                        (
                            Job::Processes(shared.process_reports.pop_front().unwrap()),
                            stream,
                            gen,
                        )
                    } else if shared.client.is_some() && !shared.text_snapshot_pending.is_empty() {
                        let (lines, bytes) = shared.text_snapshot_pending.pop_front().unwrap();
                        let snapshot = shared.screen.text_snapshot(lines, bytes);
                        let encoded =
                            serde_json::to_vec(&snapshot).unwrap_or_else(|_| b"{}".to_vec());
                        (Job::TextSnapshot(encoded), stream, gen)
                    } else {
                        let status = shared.exit_status.unwrap_or(0);
                        let snapshot = shared.screen.text_snapshot(0, 64 * 1024);
                        let encoded =
                            serde_json::to_vec(&snapshot).unwrap_or_else(|_| b"{}".to_vec());
                        (
                            Job::Exit(status, shared.screen.repaint(false), encoded),
                            stream,
                            gen,
                        )
                    }
                };

                match job {
                    // Undeliverable frames are simply dropped: the emulator
                    // has the bytes, and any future client starts from a
                    // repaint that covers them.
                    Job::Output(chunk) => send_or_drop(&state, stream, gen, T_OUTPUT, &chunk),
                    Job::Cwd(cwd) => send_or_drop(&state, stream, gen, T_CWD, cwd.as_bytes()),
                    Job::Agent(payload) => send_or_drop(&state, stream, gen, T_AGENT, &payload),
                    Job::Processes(payload) => {
                        send_or_drop(&state, stream, gen, T_PROCESSES, &payload)
                    }
                    Job::Repaint(repaint) => {
                        send_or_drop(&state, stream, gen, T_REPAINT, &repaint);
                        finish_repaint(&state, gen);
                    }
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
        if configure_client_stream(&stream).is_err() {
            continue;
        }

        if !authenticate_client(&mut stream, &config.token) {
            continue;
        }

        let hello = format!(
            "{{\"pid\":{},\"rows\":{},\"cols\":{},\"proto\":5}}",
            shell_pid, config.rows, config.cols
        );
        if write_frame(&mut stream, T_HELLO, hello.as_bytes()).is_err() {
            continue;
        }

        let my_gen = {
            let mut active_input_gen = state.input_generation.lock().unwrap();
            let mut shared = state.shared.lock().unwrap();
            if let Some(old) = shared.client.take() {
                let _ = old.shutdown(std::net::Shutdown::Both);
            }
            // Bytes for the previous client are already folded into the
            // emulator; the new client starts from a repaint it requests.
            shared.transit.clear();
            shared.repaint_pending.clear();
            shared.repaint_frozen = false;
            shared.text_snapshot_pending.clear();
            shared.client = stream.try_clone().ok();
            shared.client_gen += 1;
            *active_input_gen = shared.client_gen;
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
                        let Some(writer) = writer.as_mut() else {
                            break;
                        };
                        match write_input_if_current(
                            &state.input_generation,
                            my_gen,
                            &mut **writer,
                            &data,
                        ) {
                            Ok(true) => {}
                            Ok(false) | Err(_) => break,
                        }
                    }
                    Ok((T_RESIZE, data)) if data.len() == 4 => {
                        let rows = u16::from_be_bytes([data[0], data[1]]);
                        let cols = u16::from_be_bytes([data[2], data[3]]);
                        let (rows, cols) = clamp_dims(rows, cols);
                        let mut shared = state.shared.lock().unwrap();
                        while shared.client_gen == my_gen && shared.repaint_frozen {
                            shared = state.cond.wait(shared).unwrap();
                        }
                        if shared.client_gen != my_gen {
                            break;
                        }

                        shared.screen.resize(rows, cols);
                        if let Some(master) = master.lock().unwrap().as_mut() {
                            let _ = master.0.resize(PtySize {
                                rows,
                                cols,
                                pixel_width: 0,
                                pixel_height: 0,
                            });
                        }
                    }
                    Ok((T_REPAINT_REQ, data)) => {
                        let (cols, history_budget) = parse_repaint_request(&data);
                        let mut shared = state.shared.lock().unwrap();
                        if shared.client_gen != my_gen {
                            break;
                        }

                        // Alacritty intentionally buffers synchronized-update
                        // blocks. A repaint is itself an atomic visual update,
                        // so materialize that block before freezing the grid.
                        shared.screen.finish_synchronized_update();
                        let pending = PendingRepaint::new(&shared.transit, cols, history_budget);
                        if enqueue_repaint_bounded(&mut shared.repaint_pending, pending) {
                            shared.repaint_frozen = true;
                        }
                        state.cond.notify_all();
                    }
                    Ok((T_TEXT_SNAPSHOT_REQ, data)) if data.len() == 8 => {
                        let lines = u32::from_be_bytes(data[0..4].try_into().unwrap()) as usize;
                        let bytes = u32::from_be_bytes(data[4..8].try_into().unwrap()) as usize;
                        let lines = lines.min(50_000);
                        let bytes = bytes.clamp(1, 128 * 1024);
                        match queue_text_snapshot_request(&state, my_gen, (lines, bytes)) {
                            TextSnapshotRequestResult::Queued => {}
                            TextSnapshotRequestResult::Stale
                            | TextSnapshotRequestResult::Overloaded => break,
                        }
                    }
                    Ok((T_PROCESSES_REQ, _)) => {
                        let payload = serde_json::to_vec(&process_tree(shell_pid))
                            .unwrap_or_else(|_| b"[]".to_vec());
                        let mut shared = state.shared.lock().unwrap();
                        shared.process_reports.push_back(payload);
                        state.cond.notify_all();
                    }
                    Ok((T_KILL, _)) => {
                        let shared = state.shared.lock().unwrap();
                        if shared.client_gen != my_gen {
                            break;
                        }
                        let _ = killer.lock().unwrap().kill();
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }

            detach_client_if_current(&state, my_gen);
        });
    }
}

fn parse_repaint_request(data: &[u8]) -> (u16, usize) {
    let cols = if data.len() >= 2 {
        u16::from_be_bytes([data[0], data[1]])
    } else {
        0
    };
    let history_budget = if data.len() >= 6 {
        u32::from_be_bytes(data[2..6].try_into().unwrap()) as usize
    } else {
        REPAINT_HISTORY_BUDGET
    };
    (cols, history_budget.min(REPAINT_HISTORY_BUDGET))
}

fn configure_client_stream(stream: &LocalStream) -> std::io::Result<()> {
    stream.set_write_timeout(Some(CLIENT_WRITE_TIMEOUT))
}

#[cfg(all(test, unix))]
fn local_stream_pair() -> std::io::Result<(LocalStream, LocalStream)> {
    UnixStream::pair()
}

#[cfg(all(test, windows))]
fn local_stream_pair() -> std::io::Result<(LocalStream, LocalStream)> {
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
    let address = listener.local_addr()?;
    let peer = TcpStream::connect(address)?;
    let (accepted, _) = listener.accept()?;
    Ok((accepted, peer))
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
        // VTE ends OSC on BEL, CAN, SUB or any ESC (ST consumes the following
        // backslash too). Pick the earliest terminator; preferring a later BEL
        // would accidentally swallow a valid OSC that follows a cancellation.
        let body = &hay[body_start..];
        let single = body
            .iter()
            .position(|&b| matches!(b, 0x07 | 0x18 | 0x1a))
            .map(|i| (body_start + i, 1));
        let escape = body.iter().position(|&b| b == 0x1b).map(|i| {
            let term_len = if body.get(i + 1) == Some(&b'\\') {
                2
            } else {
                1
            };
            (body_start + i, term_len)
        });
        let end = match (single, escape) {
            (Some(a), Some(b)) => Some(if a.0 <= b.0 { a } else { b }),
            (a, b) => a.or(b),
        };

        let Some((end, term_len)) = end else {
            // Unterminated: keep from the sequence start for the next read.
            *tail = hay[start..].to_vec();
            tail.truncate(TAIL_KEEP);
            return;
        };

        let body = &hay[body_start..end];
        if let Some(url) = body.strip_prefix(b"7;") {
            if let Ok(url) = std::str::from_utf8(url) {
                if let Some(path) = osc_file_path(url) {
                    out.cwd = Some(path);
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
        // A bare ESC terminates the current OSC, but it may simultaneously
        // be the introducer of the next `ESC ]` sequence. Re-scan from that
        // byte so adjacent reports are not lost. BEL/CAN/SUB and the two-byte
        // ST (`ESC \`) are fully consumed before the next search.
        search_from = if term_len == 1 && hay.get(end) == Some(&0x1b) {
            end
        } else {
            end + term_len
        };
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

#[cfg(windows)]
fn process_tree(root_pid: u32) -> Vec<ProcessInfo> {
    use std::collections::HashSet;
    use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::nothing()
            .with_exe(UpdateKind::Always)
            .with_cmd(UpdateKind::Always),
    );
    let mut descendants = HashSet::from([root_pid]);

    loop {
        let before = descendants.len();
        for (pid, process) in system.processes() {
            if process
                .parent()
                .is_some_and(|parent| descendants.contains(&parent.as_u32()))
            {
                descendants.insert(pid.as_u32());
            }
        }
        if descendants.len() == before {
            break;
        }
    }

    let mut processes: Vec<ProcessInfo> = system
        .processes()
        .iter()
        .filter(|(pid, _)| pid.as_u32() != root_pid && descendants.contains(&pid.as_u32()))
        .map(|(pid, process)| ProcessInfo {
            pid: pid.as_u32(),
            parent_pid: process.parent().map(|parent| parent.as_u32()),
            executable: process
                .exe()
                .map(|path| path.to_string_lossy().into_owned())
                .unwrap_or_else(|| process.name().to_string_lossy().into_owned()),
            argv: process
                .cmd()
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect(),
        })
        .collect();
    processes.sort_by_key(|process| process.pid);
    processes
}

fn osc_file_path(url: &str) -> Option<String> {
    let rest = url.strip_prefix("file://")?;
    let (host, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    let decoded = percent_decode(path)?;

    #[cfg(windows)]
    {
        let normalized = if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
            if decoded.as_bytes().get(2) == Some(&b':') && decoded.starts_with('/') {
                decoded[1..].to_owned()
            } else {
                decoded
            }
        } else {
            format!("//{host}{decoded}")
        };
        Some(normalized.replace('/', "\\"))
    }

    #[cfg(not(windows))]
    {
        let _ = host;
        Some(decoded)
    }
}

#[cfg(not(windows))]
fn process_tree(_root_pid: u32) -> Vec<ProcessInfo> {
    Vec::new()
}

fn run_exec_proxy(raw: &str) -> ! {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    let config: ExecConfig = serde_json::from_str(raw).unwrap_or_else(|e| {
        eprintln!("dala_holder exec: bad config json: {e}");
        exit(2);
    });
    let Some((program, args)) = config.command.split_first() else {
        eprintln!("dala_holder exec: command must not be empty");
        exit(2);
    };

    let stderr = if config.stderr == "/dev/null" {
        Stdio::null()
    } else {
        let path = PathBuf::from(&config.stderr);
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)
            .unwrap_or_else(|e| {
                eprintln!("dala_holder exec: stderr: {e}");
                exit(1);
            });
        Stdio::from(file)
    };

    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(stderr)
        .spawn()
        .unwrap_or_else(|e| {
            eprintln!("dala_holder exec: spawn {program}: {e}");
            exit(1);
        });

    #[cfg(windows)]
    let _job = WindowsJob::assign(&child).ok();

    let mut child_stdin = child.stdin.take().unwrap();
    let mut child_stdout = child.stdout.take().unwrap();
    let (eof_tx, eof_rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let _ = std::io::copy(&mut std::io::stdin().lock(), &mut child_stdin);
        let _ = child_stdin.flush();
        let _ = eof_tx.send(());
    });
    let output = thread::spawn(move || {
        let _ = std::io::copy(&mut child_stdout, &mut std::io::stdout().lock());
        let _ = std::io::stdout().flush();
    });

    let mut eof_at = None;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None)
                if eof_at.is_some_and(|at: Instant| at.elapsed() >= Duration::from_millis(100)) =>
            {
                let _ = child.kill();
                break child.wait().unwrap_or_else(|e| {
                    eprintln!("dala_holder exec: wait: {e}");
                    exit(1);
                });
            }
            Ok(None) => {
                if eof_at.is_none() && eof_rx.try_recv().is_ok() {
                    eof_at = Some(Instant::now());
                }
                thread::sleep(Duration::from_millis(20));
            }
            Err(e) => {
                eprintln!("dala_holder exec: wait: {e}");
                exit(1);
            }
        }
    };
    let _ = output.join();
    exit(status.code().unwrap_or(1));
}

#[cfg(windows)]
struct WindowsJob(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl WindowsJob {
    fn assign(child: &std::process::Child) -> std::io::Result<Self> {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::System::JobObjects::{
            AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
            SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        };

        unsafe {
            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            if SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const std::ffi::c_void,
                std::mem::size_of_val(&limits) as u32,
            ) == 0
                || AssignProcessToJobObject(job, child.as_raw_handle() as _) == 0
            {
                windows_sys::Win32::Foundation::CloseHandle(job);
                return Err(std::io::Error::last_os_error());
            }
            Ok(Self(job))
        }
    }
}

#[cfg(windows)]
impl Drop for WindowsJob {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

fn usage() -> ! {
    eprintln!(
        "usage: dala_holder '<config json>' | dala_holder watch | dala_holder exec '<config json>'"
    );
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

#[cfg(unix)]
fn bind_local(path: &std::path::Path, _token: &str) -> std::io::Result<LocalListener> {
    UnixListener::bind(path)
}

#[cfg(windows)]
fn bind_local(path: &std::path::Path, token: &str) -> std::io::Result<LocalListener> {
    if token.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "an authentication token is required",
        ));
    }

    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
    let port = listener.local_addr()?.port();
    let endpoint = serde_json::json!({
        "host": "127.0.0.1",
        "port": port,
        "token": token,
    });
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(format!(".{}.tmp", std::process::id()));
    let temporary = PathBuf::from(temporary);
    std::fs::write(&temporary, serde_json::to_vec(&endpoint)?)?;
    let _ = std::fs::remove_file(path);
    std::fs::rename(temporary, path)?;
    Ok(listener)
}

#[cfg(unix)]
fn authenticate_client(_stream: &mut LocalStream, _token: &str) -> bool {
    true
}

#[cfg(windows)]
fn authenticate_client(stream: &mut LocalStream, token: &str) -> bool {
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));
    let authenticated =
        matches!(read_frame(stream), Ok((T_AUTH, supplied)) if supplied == token.as_bytes());
    let _ = stream.set_read_timeout(None);
    authenticated
}

#[cfg(unix)]
fn acquire_session_lock(_path: &std::path::Path) -> std::io::Result<Option<std::fs::File>> {
    Ok(None)
}

#[cfg(windows)]
fn acquire_session_lock(path: &std::path::Path) -> std::io::Result<Option<std::fs::File>> {
    use fs2::FileExt;

    let mut lock_path = path.as_os_str().to_owned();
    lock_path.push(".lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(PathBuf::from(lock_path))?;
    file.try_lock_exclusive()?;
    Ok(Some(file))
}

#[cfg(windows)]
fn spawn_windows_child(config: &str) -> ! {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let mut parsed: Config = serde_json::from_str(config).unwrap_or_else(|e| {
        eprintln!("dala_holder: bad config json: {e}");
        exit(2);
    });
    merge_windows_launch_env(&mut parsed);
    let socket_path = PathBuf::from(&parsed.socket);
    if let Some(dir) = socket_path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let executable = std::env::current_exe().unwrap_or_else(|e| {
        eprintln!("dala_holder: current executable: {e}");
        exit(1);
    });

    let mut config_path = socket_path.as_os_str().to_owned();
    config_path.push(".launch.json");
    let config_path = PathBuf::from(config_path);
    let launch_config = serde_json::to_vec(&parsed).unwrap_or_else(|error| {
        eprintln!("dala_holder: serialize launch config: {error}");
        exit(1);
    });
    if let Err(error) = std::fs::write(&config_path, launch_config) {
        eprintln!("dala_holder: write launch config: {error}");
        exit(1);
    }

    // Erlang Port programs run in a kill-on-close Job Object. WMI creates the
    // real holder from the system provider process, outside that Job, so the
    // PTY and shell survive a BEAM restart. The command line contains only a
    // config-file path; the authentication token never appears in process args.
    let command_line = format!(
        "{} --holder-config {}",
        quote_windows_arg(&executable),
        quote_windows_arg(&config_path)
    );
    let script = concat!(
        "$startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly ",
        "-Property @{ShowWindow=[uint16]0}; ",
        "$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create ",
        "-Arguments @{CommandLine=$env:DALA_HOLDER_COMMAND_LINE; ",
        "ProcessStartupInformation=$startup}; ",
        "if ($null -eq $r -or $r.ReturnValue -ne 0) { ",
        "Write-Error ('Win32_Process.Create failed: ' + $r.ReturnValue); exit 1 }"
    );

    let result = Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .env("DALA_HOLDER_COMMAND_LINE", command_line)
        .creation_flags(CREATE_NO_WINDOW)
        .output();

    match result {
        Ok(output) if output.status.success() => exit(0),
        Ok(output) => {
            let _ = std::fs::remove_file(&config_path);
            let error = String::from_utf8_lossy(&output.stderr);
            eprintln!("dala_holder: WMI launch failed: {}", error.trim());
            exit(1);
        }
        Err(error) => {
            let _ = std::fs::remove_file(&config_path);
            eprintln!("dala_holder: start Windows process broker: {error}");
            exit(1);
        }
    }
}

#[cfg(windows)]
fn merge_windows_launch_env(config: &mut Config) {
    use std::collections::{BTreeMap, HashSet};

    let removed: HashSet<String> = config
        .env_remove
        .iter()
        .map(|key| key.to_lowercase())
        .collect();
    let mut merged = BTreeMap::new();

    for (key, value) in std::env::vars_os() {
        let (Ok(key), Ok(value)) = (key.into_string(), value.into_string()) else {
            continue;
        };
        let comparison_key = key.to_lowercase();
        if !removed.contains(&comparison_key) {
            merged.insert(comparison_key, (key, value));
        }
    }

    for (key, value) in std::mem::take(&mut config.env) {
        merged.insert(key.to_lowercase(), (key, value));
    }

    config.env = merged.into_values().collect();
}

#[cfg(windows)]
fn quote_windows_arg(path: &std::path::Path) -> String {
    let value = path.to_string_lossy();
    format!("\"{}\"", value.replace('"', "\\\""))
}

/// The BEAM ignores SIGCHLD (and that survives exec), which breaks child-exit
/// detection in anything it spawns — restore defaults before doing any work.
#[cfg(unix)]
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
#[cfg(unix)]
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
fn send_or_drop(
    state: &State,
    stream: Option<LocalStream>,
    gen: u64,
    frame_type: u8,
    payload: &[u8],
) {
    let delivered = stream
        .map(|mut stream| write_frame(&mut stream, frame_type, payload).is_ok())
        .unwrap_or(false);

    if !delivered {
        detach_client_if_current(state, gen);
    }
}

fn finish_repaint(state: &State, gen: u64) {
    let mut shared = state.shared.lock().unwrap();
    if shared.client_gen == gen && (shared.client.is_none() || shared.repaint_pending.is_empty()) {
        shared.repaint_frozen = false;
        state.cond.notify_all();
    }
}

fn clear_client(shared: &mut Shared) {
    if let Some(client) = shared.client.take() {
        // UnixStream clones share one socket. Shutdown wakes the control
        // reader and tells the BEAM immediately when the writer timed out.
        let _ = client.shutdown(std::net::Shutdown::Both);
    }
    shared.transit.clear();
    shared.repaint_pending.clear();
    shared.repaint_frozen = false;
    shared.text_snapshot_pending.clear();
}

/// Detaches only the expected connection generation. The input gate is
/// acquired first everywhere that changes ownership, so a frame already read
/// by the old control thread either finishes before detach or observes the new
/// generation. Bumping both generations also invalidates every stale control
/// thread before PTY ingestion is unfrozen.
fn detach_client_if_current(state: &State, expected_gen: u64) -> bool {
    let mut active_input_gen = state.input_generation.lock().unwrap();
    let mut shared = state.shared.lock().unwrap();
    if shared.client_gen != expected_gen {
        return false;
    }

    clear_client(&mut shared);
    shared.client_gen += 1;
    *active_input_gen = shared.client_gen;
    state.cond.notify_all();
    true
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
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "bad frame",
        ));
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
    fn repaint_request_supports_fast_screen_and_legacy_clients() {
        assert_eq!(
            parse_repaint_request(&80u16.to_be_bytes()),
            (80, REPAINT_HISTORY_BUDGET)
        );

        let mut fast = 120u16.to_be_bytes().to_vec();
        fast.extend(0u32.to_be_bytes());
        assert_eq!(parse_repaint_request(&fast), (120, 0));

        let mut oversized = 90u16.to_be_bytes().to_vec();
        oversized.extend(u32::MAX.to_be_bytes());
        assert_eq!(
            parse_repaint_request(&oversized),
            (90, REPAINT_HISTORY_BUDGET)
        );
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
            T_HELLO,
            T_OUTPUT,
            T_EXIT,
            T_REPAINT,
            T_CWD,
            T_AGENT,
            T_INPUT,
            T_RESIZE,
            T_KILL,
            T_TEXT_SNAPSHOT,
            T_REPAINT_REQ,
            T_TEXT_SNAPSHOT_REQ,
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

    #[test]
    fn client_writer_clones_inherit_a_finite_write_timeout() {
        let (accepted, _peer) = local_stream_pair().unwrap();

        configure_client_stream(&accepted).unwrap();
        let writer = accepted.try_clone().unwrap();

        assert_eq!(
            accepted.write_timeout().unwrap(),
            Some(CLIENT_WRITE_TIMEOUT)
        );
        assert_eq!(writer.write_timeout().unwrap(), Some(CLIENT_WRITE_TIMEOUT));
    }
}

#[cfg(test)]
mod client_generation_tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    struct BlockingWriter {
        entered: mpsc::Sender<()>,
        release: Arc<(Mutex<bool>, Condvar)>,
        bytes: Arc<Mutex<Vec<u8>>>,
    }

    impl Write for BlockingWriter {
        fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
            let _ = self.entered.send(());
            let (released, cond) = &*self.release;
            let mut released = released.lock().unwrap();
            while !*released {
                released = cond.wait(released).unwrap();
            }
            self.bytes.lock().unwrap().extend_from_slice(data);
            Ok(data.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn frozen_state(generation: u64) -> State {
        let mut transit = TransitQueue::default();
        transit.push_bounded(b"pending output", RING_MAX);

        State {
            input_generation: Mutex::new(generation),
            shared: Mutex::new(Shared {
                transit,
                client: None,
                client_gen: generation,
                exit_status: None,
                pty_done: false,
                screen: Screen::new(24, 80, 100),
                repaint_pending: VecDeque::from([PendingRepaint {
                    barrier: 0,
                    cols: 80,
                    history_budget: 0,
                }]),
                repaint_frozen: true,
                text_snapshot_pending: VecDeque::from([(10, 1024)]),
                cwd_report: None,
                agent_reports: VecDeque::new(),
                process_reports: VecDeque::new(),
                osc_tail: Vec::new(),
            }),
            cond: Condvar::new(),
        }
    }

    #[test]
    fn active_detach_invalidates_control_threads_and_unfreezes_ingestion() {
        let state = frozen_state(7);

        assert!(detach_client_if_current(&state, 7));

        let active_input_gen = state.input_generation.lock().unwrap();
        let shared = state.shared.lock().unwrap();
        assert_eq!(*active_input_gen, 8);
        assert_eq!(shared.client_gen, 8);
        assert!(shared.transit.is_empty());
        assert!(shared.repaint_pending.is_empty());
        assert!(!shared.repaint_frozen);
        assert!(shared.text_snapshot_pending.is_empty());
    }

    #[test]
    fn active_detach_shuts_down_every_clone_of_the_client_socket() {
        let state = frozen_state(7);
        let (holder, mut peer) = local_stream_pair().unwrap();
        let _control_thread_clone = holder.try_clone().unwrap();
        peer.set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        state.shared.lock().unwrap().client = Some(holder);

        assert!(detach_client_if_current(&state, 7));

        let mut byte = [0u8; 1];
        assert_eq!(peer.read(&mut byte).unwrap(), 0);
    }

    #[test]
    fn stale_detach_cannot_clear_the_current_connection_state() {
        let state = frozen_state(11);

        assert!(!detach_client_if_current(&state, 10));

        let active_input_gen = state.input_generation.lock().unwrap();
        let shared = state.shared.lock().unwrap();
        assert_eq!(*active_input_gen, 11);
        assert_eq!(shared.client_gen, 11);
        assert!(!shared.transit.is_empty());
        assert_eq!(shared.repaint_pending.len(), 1);
        assert!(shared.repaint_frozen);
        assert_eq!(shared.text_snapshot_pending.len(), 1);
    }

    #[test]
    fn text_snapshot_overload_detaches_instead_of_shifting_ref_less_responses() {
        let state = frozen_state(7);
        {
            let mut shared = state.shared.lock().unwrap();
            shared.text_snapshot_pending = (0..MAX_PENDING_TEXT_SNAPSHOTS)
                .map(|sequence| (sequence, 1024))
                .collect();
        }

        assert_eq!(
            queue_text_snapshot_request(&state, 7, (usize::MAX, 1024)),
            TextSnapshotRequestResult::Overloaded
        );

        let active_input_gen = state.input_generation.lock().unwrap();
        let shared = state.shared.lock().unwrap();
        assert_eq!(*active_input_gen, 8);
        assert_eq!(shared.client_gen, 8);
        assert!(shared.text_snapshot_pending.is_empty());
        assert!(!shared.repaint_frozen);
    }

    #[test]
    fn blocked_input_write_does_not_hold_the_generation_gate() {
        let generation = Arc::new(Mutex::new(7));
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let bytes = Arc::new(Mutex::new(Vec::new()));
        let (entered_tx, entered_rx) = mpsc::channel();
        let mut writer = BlockingWriter {
            entered: entered_tx,
            release: Arc::clone(&release),
            bytes: Arc::clone(&bytes),
        };
        let input_generation = Arc::clone(&generation);

        let input = thread::spawn(move || {
            write_input_if_current(&input_generation, 7, &mut writer, b"old input")
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();

        let (handoff_tx, handoff_rx) = mpsc::channel();
        let handoff_generation = Arc::clone(&generation);
        let handoff = thread::spawn(move || {
            *handoff_generation.lock().unwrap() = 8;
            handoff_tx.send(()).unwrap();
        });

        handoff_rx
            .recv_timeout(Duration::from_millis(250))
            .expect("PTY backpressure must not block a new connection handoff");

        let (released, cond) = &*release;
        *released.lock().unwrap() = true;
        cond.notify_all();

        assert!(input.join().unwrap().unwrap());
        handoff.join().unwrap();
        assert_eq!(&*bytes.lock().unwrap(), b"old input");
    }

    #[test]
    fn stale_input_generation_never_reaches_the_pty_writer() {
        let generation = Mutex::new(9);
        let mut bytes = Vec::new();

        assert!(!write_input_if_current(&generation, 8, &mut bytes, b"stale input").unwrap());
        assert!(bytes.is_empty());
    }
}

#[cfg(windows)]
fn daemonize(_socket_path: &std::path::Path) {}

#[cfg(windows)]
fn reset_signals() {}

#[cfg(all(test, windows))]
mod windows_transport_tests {
    use super::*;

    #[test]
    fn bind_local_publishes_authenticated_loopback_endpoint() {
        let dir = std::env::temp_dir().join(format!("dala-holder-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let endpoint = dir.join("session.sock");

        let listener = bind_local(&endpoint, "test-token").unwrap();
        let published: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&endpoint).unwrap()).unwrap();

        assert_eq!(published["host"], "127.0.0.1");
        assert!(published["port"].as_u64().unwrap() > 0);
        assert_eq!(published["token"], "test-token");

        drop(listener);
        let _ = std::fs::remove_dir_all(dir);
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
mod repaint_fairness_tests {
    use super::*;

    #[test]
    fn repaint_barrier_holds_new_output_until_the_snapshot() {
        let mut transit = TransitQueue::default();
        transit.push_bounded(b"before", 64);
        let barrier = transit.end_position();
        transit.push_bounded(b"after", 64);

        assert_eq!(transit.drain_before(Some(barrier), CHUNK), b"before");
        assert!(transit.reached(barrier));
        assert_eq!(transit.drain_before(None, CHUNK), b"after");
    }

    #[test]
    fn queued_repaints_each_get_a_fair_output_boundary() {
        let mut transit = TransitQueue::default();
        transit.push_bounded(b"one", 64);
        let first = transit.end_position();
        transit.push_bounded(b"two", 64);
        let second = transit.end_position();
        transit.push_bounded(b"three", 64);

        assert_eq!(transit.drain_before(Some(first), CHUNK), b"one");
        assert!(transit.reached(first));
        assert_eq!(transit.drain_before(Some(second), CHUNK), b"two");
        assert!(transit.reached(second));
        assert_eq!(transit.drain_before(None, CHUNK), b"three");
    }

    #[test]
    fn output_selected_for_an_in_flight_write_stays_before_a_later_barrier() {
        let mut transit = TransitQueue::default();
        transit.push_bounded(b"first-safe-frame", 128);

        // The sole writer removes a whole parser-safe frame before releasing
        // the shared lock, then performs the socket write without the lock.
        let in_flight = transit.drain_before(None, CHUNK);
        assert_eq!(in_flight, b"first-safe-frame");

        // PTY ingestion can queue another safe frame while that write is in
        // flight. A repaint requested now must wait only for this second
        // frame; the already selected frame is ordered first by the sole
        // writer and is not counted in the new barrier.
        transit.push_bounded(b"second-safe-frame", 128);
        let barrier = transit.end_position();
        assert_eq!(
            transit.drain_before(Some(barrier), CHUNK),
            b"second-safe-frame"
        );
        assert!(transit.reached(barrier));
    }

    #[test]
    fn overflow_advances_past_a_repaint_barrier_without_starving_it() {
        let mut transit = TransitQueue::default();
        transit.push_bounded(b"old!", 8);
        let barrier = transit.end_position();
        assert_eq!(transit.push_bounded(b"new-data", 8), 4);

        assert!(transit.reached(barrier));
        assert_eq!(transit.drain_before(None, CHUNK), b"new-data");
    }

    #[test]
    fn overflow_and_socket_chunking_preserve_parser_safe_boundaries() {
        let mut parser = ParserSafeOutput::default();
        let old = parser.push(b"old");
        let ansi_utf8 = parser.push("\x1b[31m中\x1b[0m".as_bytes());
        assert!(!old.is_empty());
        assert!(!ansi_utf8.is_empty());

        let mut transit = TransitQueue::default();
        transit.push_bounded(&old, ansi_utf8.len());
        assert_eq!(transit.push_bounded(&ansi_utf8, ansi_utf8.len()), old.len());

        // Even a preferred frame size inside the CSI/UTF-8 token may not
        // split the safe chunk. The first retained frame is a complete token
        // sequence that begins and ends in parser ground state.
        assert_eq!(transit.drain_before(None, 2), ansi_utf8);
        assert!(transit.is_empty());
    }

    #[test]
    fn an_individually_oversized_safe_chunk_is_dropped_whole() {
        let mut transit = TransitQueue::default();
        let safe = b"complete-safe-chunk";

        assert_eq!(transit.push_bounded(safe, safe.len() - 1), safe.len());
        assert!(transit.is_empty());
    }

    #[test]
    fn repaint_payload_is_generated_from_the_latest_frozen_screen() {
        let mut screen = Screen::new(4, 80, 100);
        let mut transit = TransitQueue::default();
        screen.advance(b"BEFORE\r\n");
        transit.push_bounded(b"BEFORE\r\n", 64);

        let pending = PendingRepaint::new(&transit, 80, 0);
        screen.advance(b"AFTER\r\n");
        let soft = pending.cols as usize == screen.columns();
        let payload = screen.repaint_with_history(soft, pending.history_budget);
        let snapshot = String::from_utf8_lossy(&payload);
        assert!(snapshot.contains("BEFORE"));
        assert!(snapshot.contains("AFTER"));
        assert_eq!(pending.barrier, b"BEFORE\r\n".len() as u64);
    }

    #[test]
    fn repeated_overflow_never_moves_the_repaint_barrier() {
        let mut transit = TransitQueue::default();
        transit.push_bounded(b"BEFORE\r\n", 64);
        let pending = PendingRepaint::new(&transit, 80, 0);
        let requested_at = pending.barrier;

        for _ in 0..10 {
            assert!(transit.push_bounded(b"01234567", 4) > 0);
            assert_eq!(pending.barrier, requested_at);
        }

        assert!(transit.reached(pending.barrier));
    }

    #[test]
    fn queued_repaint_stores_metadata_not_a_materialized_snapshot() {
        assert!(std::mem::size_of::<PendingRepaint>() <= 32);
    }

    #[test]
    fn repaint_queue_refuses_overload_without_shifting_fifo_responses() {
        let mut pending = VecDeque::new();
        for barrier in 0..MAX_PENDING_REPAINTS as u64 {
            assert!(enqueue_repaint_bounded(
                &mut pending,
                PendingRepaint {
                    barrier,
                    cols: 80,
                    history_budget: 0,
                }
            ));
        }

        assert!(!enqueue_repaint_bounded(
            &mut pending,
            PendingRepaint {
                barrier: u64::MAX,
                cols: 80,
                history_budget: 0,
            }
        ));
        assert_eq!(pending.len(), MAX_PENDING_REPAINTS);
        assert_eq!(pending.front().unwrap().barrier, 0);
        assert_eq!(
            pending.back().unwrap().barrier,
            MAX_PENDING_REPAINTS as u64 - 1
        );
    }

    #[test]
    fn text_snapshot_queue_has_a_hard_request_limit() {
        let mut pending = VecDeque::new();
        for sequence in 0..MAX_PENDING_TEXT_SNAPSHOTS {
            assert!(enqueue_text_snapshot_bounded(
                &mut pending,
                (sequence, 1024)
            ));
        }

        assert!(!enqueue_text_snapshot_bounded(
            &mut pending,
            (usize::MAX, 1024)
        ));
        assert_eq!(pending.len(), MAX_PENDING_TEXT_SNAPSHOTS);
        assert_eq!(pending.front(), Some(&(0, 1024)));
        assert_eq!(
            pending.back(),
            Some(&(MAX_PENDING_TEXT_SNAPSHOTS - 1, 1024))
        );
    }

    #[test]
    fn agent_queue_drops_oldest_reports_at_its_hard_limit() {
        let mut pending = VecDeque::new();
        let reports: Vec<_> = (0..MAX_AGENT_REPORTS + 3)
            .map(|sequence| sequence.to_be_bytes().to_vec())
            .collect();

        extend_agent_reports_bounded(&mut pending, reports);

        assert_eq!(pending.len(), MAX_AGENT_REPORTS);
        assert_eq!(pending.front().unwrap(), &3usize.to_be_bytes());
        assert_eq!(
            pending.back().unwrap(),
            &(MAX_AGENT_REPORTS + 2).to_be_bytes()
        );
    }
}

#[cfg(test)]
mod parser_boundary_tests {
    use super::*;

    #[test]
    fn split_csi_is_not_exposed_before_its_final_byte() {
        let mut output = ParserSafeOutput::default();

        assert!(output.push(b"\x1b[").is_empty());
        assert_eq!(output.push(b"31mRED\x1b[0m\r\n"), b"\x1b[31mRED\x1b[0m\r\n");
    }

    #[test]
    fn split_utf8_codepoint_is_not_exposed_half_encoded() {
        let mut output = ParserSafeOutput::default();

        assert!(output.push(&[0xe4]).is_empty());
        assert!(output.push(&[0xb8]).is_empty());
        assert_eq!(output.push(&[0xad, b'\n']), "中\n".as_bytes());
    }

    #[test]
    fn split_osc_and_dcs_wait_for_their_string_terminator() {
        let mut output = ParserSafeOutput::default();

        assert!(output.push(b"\x1b]0;partial").is_empty());
        assert_eq!(output.push(b" title\x07ok"), b"\x1b]0;partial title\x07ok");

        assert!(output.push(b"\x1bP$qpartial").is_empty());
        assert_eq!(output.push(b"\x1b\\done"), b"\x1bP$qpartial\x1b\\done");

        assert_eq!(output.push(b"\x1bPraw\x9cafter"), b"\x1bPraw\x9cafter");
    }

    #[test]
    fn split_c1_control_sequences_wait_for_their_terminator() {
        let mut output = ParserSafeOutput::default();

        assert!(output.push(&[0x9b, b'3']).is_empty());
        assert_eq!(output.push(b"1mred"), b"\x9b31mred");

        assert!(output.push(&[0x9d, b'0', b';']).is_empty());
        assert!(output.push(b"partial").is_empty());
        assert_eq!(output.push(b"\x07ok"), b"\x9d0;partial\x07ok");

        assert!(output.push(&[0x90, b'$', b'q']).is_empty());
        assert!(output.push(b"partial").is_empty());
        assert_eq!(
            output.push(&[0x9c, b'd', b'o', b'n', b'e']),
            b"\x90$qpartial\x9cdone"
        );

        for start in [0x98, 0x9e, 0x9f] {
            let mut control = ParserSafeOutput::default();
            assert!(control.push(&[start]).is_empty());
            assert!(control.push(b"payload").is_empty());
            assert_eq!(
                control.push(b"\x9cX"),
                [vec![start], b"payload".to_vec(), vec![0x9c, b'X']].concat()
            );
        }
    }

    #[test]
    fn utf8_continuations_are_not_mistaken_for_c1_starts() {
        let mut output = ParserSafeOutput::default();

        // U+261B is E2 98 9B; its final byte is numerically the C1 CSI
        // introducer, but remains part of the UTF-8 codepoint.
        assert!(output.push(&[0xe2, 0x98]).is_empty());
        assert_eq!(output.push(&[0x9b, b'X']), "☛X".as_bytes());
    }

    #[test]
    fn escape_cancels_a_control_string_and_processes_its_final_byte() {
        let mut output = ParserSafeOutput::default();

        assert_eq!(
            output.push(b"\x1b]unfinished\x1bx"),
            b"\x1b]unfinished\x1bx"
        );
        assert_eq!(output.push(b"ground"), b"ground");
    }

    #[test]
    fn unterminated_control_string_is_cancelled_at_the_memory_bound() {
        let mut output = ParserSafeOutput::default();
        let mut unterminated = b"\x1b]0;".to_vec();
        unterminated.resize(PARSER_TOKEN_MAX, b'x');

        let complete = output.push(&unterminated);
        assert_eq!(complete.len(), PARSER_TOKEN_MAX + 1);
        assert_eq!(complete.last(), Some(&0x18));
        assert_eq!(output.push(b"ground"), b"ground");
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
        assert_eq!(percent_decode("/a%20b/%C3%A9").as_deref(), Some("/a b/é"));
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

    #[cfg(unix)]
    fn expected_host_path(path: &str) -> String {
        path.to_owned()
    }

    #[cfg(windows)]
    fn expected_host_path(path: &str) -> String {
        format!("\\\\host{}", path.replace('/', "\\"))
    }

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
        let (cwd, _) = run(&[b"junk\x1b]7;file://localhost/tmp/x\x07more"]);
        #[cfg(unix)]
        assert_eq!(cwd.as_deref(), Some("/tmp/x"));
        #[cfg(windows)]
        assert_eq!(cwd.as_deref(), Some("\\tmp\\x"));
    }

    #[cfg(windows)]
    #[test]
    fn parses_windows_drive_and_unc_osc7_paths() {
        assert_eq!(
            osc_file_path("file:///C:/Users/Sea%20So/project").as_deref(),
            Some("C:\\Users\\Sea So\\project")
        );
        assert_eq!(
            osc_file_path("file://server/share/project").as_deref(),
            Some("\\\\server\\share\\project")
        );
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

    #[test]
    fn cancelled_osc_does_not_swallow_the_next_report() {
        let (cwd, _) = run(&[
            b"\x1b]7;file://host/bad\x18ignored",
            b"\x1b]7;file://host/good\x07",
        ]);
        assert_eq!(cwd, Some(expected_host_path("/good")));

        let (cwd, _) = run(&[b"\x1b]7;file://host/bad\x1bx\x1b]7;file://host/escaped\x07"]);
        assert_eq!(cwd, Some(expected_host_path("/escaped")));
    }

    #[test]
    fn bare_escape_terminator_can_also_start_the_next_osc_report() {
        let (cwd, _) = run(&[b"\x1b]7;file://host/old\x1b]7;file://host/new\x07"]);
        assert_eq!(cwd, Some(expected_host_path("/new")));
    }

    #[test]
    fn adjacent_bare_escape_agent_reports_are_both_delivered() {
        let (_, agents) = run(&[
            b"\x1b]777;notify;warp://cli-agent;{\"event\":\"old\"}",
            b"\x1b]777;notify;warp://cli-agent;{\"event\":\"new\"}\x07",
        ]);
        assert_eq!(agents.len(), 2);
        assert_eq!(
            agents[0],
            b"warp://cli-agent\x1f{\"event\":\"old\"}".to_vec()
        );
        assert_eq!(
            agents[1],
            b"warp://cli-agent\x1f{\"event\":\"new\"}".to_vec()
        );
    }
}
