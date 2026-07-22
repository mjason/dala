//! Integration tests for the `dala_holder watch` subcommand.
//!
//! Protocol under test: one root path per stdin line (newest replaces the
//! previous root), one changed-directory path per stdout line (debounced),
//! and — the orphan-proofing contract — exit on stdin EOF.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

struct WatchProc {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
}

impl WatchProc {
    fn spawn() -> Self {
        Self::spawn_env(&[])
    }

    fn spawn_env(envs: &[(&str, &str)]) -> Self {
        let mut command = Command::new(env!("CARGO_BIN_EXE_dala_holder"));
        command
            .arg("watch")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for (key, value) in envs {
            command.env(key, value);
        }
        let mut child = command.spawn().expect("spawn dala_holder watch");
        let stdin = child.stdin.take().unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { return };
                if tx.send(line).is_err() {
                    return;
                }
            }
        });
        WatchProc {
            child,
            stdin: Some(stdin),
            lines: rx,
        }
    }

    fn watch_root(&mut self, root: &Path) {
        let stdin = self.stdin.as_mut().unwrap();
        writeln!(stdin, "{}", root.display()).unwrap();
        stdin.flush().unwrap();
    }

    /// Recursive watch establishment is asynchronous relative to the stdin
    /// ack — poke a marker file until the first event lands.
    fn wait_established(&mut self, root: &Path) {
        let marker = root.join(".watch-established-marker");
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            std::fs::write(&marker, "x").unwrap();
            match self.lines.recv_timeout(Duration::from_millis(500)) {
                Ok(_) => break,
                Err(RecvTimeoutError::Timeout) => {
                    assert!(Instant::now() < deadline, "watch never established");
                }
                Err(RecvTimeoutError::Disconnected) => panic!("watcher died"),
            }
        }
        let _ = std::fs::remove_file(&marker);
        self.drain(Duration::from_millis(400));
    }

    /// Collects every line arriving within `window`.
    fn drain(&self, window: Duration) -> Vec<String> {
        let mut out = Vec::new();
        let deadline = Instant::now() + window;
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match self.lines.recv_timeout(left) {
                Ok(line) => out.push(line),
                Err(_) => break,
            }
        }
        out
    }

    /// Waits until a line equal to `dir` arrives; returns all lines seen.
    fn expect_dir(&self, dir: &Path, timeout: Duration) -> Vec<String> {
        let want = dir.display().to_string();
        let mut seen = Vec::new();
        let deadline = Instant::now() + timeout;
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match self.lines.recv_timeout(left) {
                Ok(line) => {
                    let hit = line == want;
                    seen.push(line);
                    if hit {
                        return seen;
                    }
                }
                Err(_) => break,
            }
        }
        panic!("no line for {want} within {timeout:?}; saw {seen:?}");
    }

    /// Waits until a line starting with `prefix` arrives; returns that line.
    fn expect_line_starting(&self, prefix: &str, timeout: Duration) -> String {
        let mut seen = Vec::new();
        let deadline = Instant::now() + timeout;
        while let Some(left) = deadline.checked_duration_since(Instant::now()) {
            match self.lines.recv_timeout(left) {
                Ok(line) => {
                    if line.starts_with(prefix) {
                        return line;
                    }
                    seen.push(line);
                }
                Err(_) => break,
            }
        }
        panic!("no line starting with {prefix:?} within {timeout:?}; saw {seen:?}");
    }

    fn wait_exit(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if self.child.try_wait().unwrap().is_some() {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for WatchProc {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn temp_root(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "dala-watch-test-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn announces_the_root_once_the_watch_is_established() {
    // The ready marker: lets the client re-list the root, catching changes
    // that raced the (asynchronous) watch establishment.
    let root = temp_root("ready");
    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.expect_dir(&root, Duration::from_secs(5));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn emits_containing_dir_for_nested_changes() {
    let root = temp_root("nested");
    let deep = root.join("sub").join("deep");
    std::fs::create_dir_all(&deep).unwrap();

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    let t0 = Instant::now();
    std::fs::write(deep.join("hello.txt"), "hi").unwrap();
    proc.expect_dir(&deep, Duration::from_secs(2));
    // Debounce is ~200ms; the whole path must stay well under a second.
    assert!(
        t0.elapsed() < Duration::from_secs(1),
        "took {:?}",
        t0.elapsed()
    );

    // Deletes are reported too.
    std::fs::remove_file(deep.join("hello.txt")).unwrap();
    proc.expect_dir(&deep, Duration::from_secs(2));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn dirs_created_after_the_watch_are_covered() {
    let root = temp_root("mkdir");
    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    let fresh = root.join("brand").join("new");
    std::fs::create_dir_all(&fresh).unwrap();
    proc.drain(Duration::from_millis(600));
    std::fs::write(fresh.join("inside.txt"), "x").unwrap();
    proc.expect_dir(&fresh, Duration::from_secs(2));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn excluded_dirs_are_silent() {
    let root = temp_root("excl");
    let nm = root.join("node_modules").join("pkg");
    let build = root.join("_build").join("test");
    std::fs::create_dir_all(&nm).unwrap();
    std::fs::create_dir_all(&build).unwrap();

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    std::fs::write(nm.join("junk.js"), "x").unwrap();
    std::fs::write(build.join("junk.beam"), "x").unwrap();
    // Control event after the excluded ones: once it arrives, the excluded
    // events (which happened first) would already have been printed.
    std::fs::write(root.join("control.txt"), "x").unwrap();
    let seen = proc.expect_dir(&root, Duration::from_secs(2));
    for line in &seen {
        assert!(!line.contains("node_modules"), "leaked: {line}");
        assert!(!line.contains("_build"), "leaked: {line}");
    }

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn git_head_is_visible_but_object_churn_is_not() {
    let root = temp_root("git");
    let git = root.join(".git");
    std::fs::create_dir_all(git.join("objects").join("ab")).unwrap();
    std::fs::create_dir_all(git.join("refs").join("heads")).unwrap();

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    std::fs::write(git.join("objects").join("ab").join("cdef"), "blob").unwrap();
    std::fs::write(git.join("index"), "idx").unwrap();
    std::fs::write(git.join("HEAD"), "ref: refs/heads/main").unwrap();
    let seen = proc.expect_dir(&git, Duration::from_secs(2));
    for line in &seen {
        assert!(!line.contains("objects"), "leaked: {line}");
    }

    // Branch tips under refs/ are visible as well.
    std::fs::write(git.join("refs").join("heads").join("main"), "sha").unwrap();
    proc.expect_dir(&git.join("refs").join("heads"), Duration::from_secs(2));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn newest_root_replaces_the_previous_one() {
    let root_a = temp_root("swap-a");
    let root_b = temp_root("swap-b");

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root_a);
    proc.wait_established(&root_a);
    proc.watch_root(&root_b);
    proc.wait_established(&root_b);

    std::fs::write(root_a.join("old-root.txt"), "x").unwrap();
    std::fs::write(root_b.join("new-root.txt"), "x").unwrap();
    let seen = proc.expect_dir(&root_b, Duration::from_secs(2));
    let old = root_a.display().to_string();
    for line in &seen {
        assert!(line != &old, "old root still watched: {line}");
    }

    let _ = std::fs::remove_dir_all(&root_a);
    let _ = std::fs::remove_dir_all(&root_b);
}

#[test]
fn exits_within_a_second_of_stdin_eof() {
    let root = temp_root("eof");
    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    // The BEAM dying (even SIGKILL) closes the port pipe — modeled here by
    // dropping stdin. The watcher must exit on its own: no orphans, ever.
    drop(proc.stdin.take());
    assert!(
        proc.wait_exit(Duration::from_secs(1)),
        "watcher outlived stdin"
    );

    let _ = std::fs::remove_dir_all(&root);
}

/// Counts the child's live inotify watch descriptors via /proc — the direct
/// observable for "excluded dirs consume zero watches".
#[cfg(target_os = "linux")]
fn inotify_watch_count(pid: u32) -> usize {
    let fd_dir = format!("/proc/{pid}/fd");
    let mut total = 0;
    for entry in std::fs::read_dir(&fd_dir)
        .expect("read /proc fd dir")
        .flatten()
    {
        let Ok(target) = std::fs::read_link(entry.path()) else {
            continue;
        };
        if target.to_string_lossy().contains("inotify") {
            let fdinfo = format!("/proc/{pid}/fdinfo/{}", entry.file_name().to_string_lossy());
            if let Ok(info) = std::fs::read_to_string(&fdinfo) {
                total += info
                    .lines()
                    .filter(|l| l.starts_with("inotify wd:"))
                    .count();
            }
        }
    }
    total
}

#[cfg(target_os = "linux")]
#[test]
fn excluded_dirs_consume_zero_watch_descriptors() {
    let root = temp_root("zero-watch");
    std::fs::create_dir_all(root.join("sub")).unwrap();
    for i in 0..40 {
        std::fs::create_dir_all(root.join(format!("node_modules/pkg{i}"))).unwrap();
    }

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    // Registered: the root and sub — NOT the 41 node_modules dirs. A couple
    // of watches of slack for backend internals, nothing more.
    let count = inotify_watch_count(proc.child.id());
    assert!(
        (2..=5).contains(&count),
        "expected ~2 watches (root + sub), got {count} — excluded dirs consumed descriptors"
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn root_inside_an_excluded_name_still_emits() {
    // A project LIVING under a dir named like an excluded tree (~/work/target/x,
    // a drawer rooted inside node_modules) must still report: exclusion is
    // relative to the root, not absolute.
    let base = temp_root("excl-root");
    let root = base.join("node_modules").join("myproject");
    std::fs::create_dir_all(&root).unwrap();

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    std::fs::write(root.join("real-file.txt"), "x").unwrap();
    proc.expect_dir(&root, Duration::from_secs(2));

    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn renamed_in_trees_are_covered() {
    let base = temp_root("rename-in");
    let root = base.join("root");
    let outside = base.join("outside").join("tree").join("deep");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&outside).unwrap();

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.wait_established(&root);

    // Move a whole tree in; its dirs must be registered dynamically.
    std::fs::rename(base.join("outside"), root.join("moved")).unwrap();
    proc.drain(Duration::from_millis(600));
    let deep = root.join("moved").join("tree").join("deep");
    std::fs::write(deep.join("inside.txt"), "x").unwrap();
    proc.expect_dir(&deep, Duration::from_secs(2));

    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn budget_exceeded_prints_the_fallback_sentinel() {
    let root = temp_root("budget");
    for i in 0..10 {
        std::fs::create_dir_all(root.join(format!("dir{i}"))).unwrap();
    }

    let mut proc = WatchProc::spawn_env(&[("DALA_WATCH_DIR_BUDGET", "5")]);
    proc.watch_root(&root);
    proc.expect_line_starting("!fallback", Duration::from_secs(5));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn home_root_prints_the_fallback_sentinel() {
    // Watching $HOME itself (or /) is a resource-exhaustion trap — refuse
    // and tell the server to poll instead.
    let root = temp_root("home");
    let mut proc = WatchProc::spawn_env(&[("HOME", root.to_str().unwrap())]);
    proc.watch_root(&root);
    proc.expect_line_starting("!fallback", Duration::from_secs(5));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn slash_root_prints_the_fallback_sentinel() {
    let mut root = std::env::current_dir().unwrap();
    while let Some(parent) = root.parent() {
        root = parent.to_path_buf();
    }
    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.expect_line_starting("!fallback", Duration::from_secs(5));
}

#[test]
fn nonexistent_root_is_tolerated_and_replaceable() {
    let root = temp_root("recover");
    let mut proc = WatchProc::spawn();
    proc.watch_root(&root.join("does-not-exist"));
    proc.expect_line_starting("!fallback", Duration::from_secs(5));
    // Still alive and able to take a valid root afterwards.
    proc.watch_root(&root);
    proc.wait_established(&root);
    std::fs::write(root.join("ok.txt"), "x").unwrap();
    proc.expect_dir(&root, Duration::from_secs(2));

    let _ = std::fs::remove_dir_all(&root);
}

#[cfg(not(windows))]
#[test]
fn root_component_preserves_legal_leading_and_trailing_spaces() {
    let base = temp_root("spaces");
    let root = base.join("  legal root  ");
    std::fs::create_dir_all(&root).unwrap();

    let mut proc = WatchProc::spawn();
    proc.watch_root(&root);
    proc.expect_dir(&root, Duration::from_secs(5));

    let _ = std::fs::remove_dir_all(&base);
}
