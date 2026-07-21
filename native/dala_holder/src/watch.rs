//! `dala_holder watch` — recursive filesystem watcher for the file drawer.
//!
//! Cross-platform via the `notify` crate (inotify on Linux, FSEvents on
//! macOS). Wire protocol, chosen so a dead BEAM can never leave an orphan:
//!
//!   stdin:  one root path per line; the newest line replaces the previous
//!           root (drawer navigation). EOF — which the OS delivers the
//!           moment the spawning BEAM dies, however it dies — means exit.
//!   stdout: one affected *directory* per line (the parent whose listing
//!           changed), coalesced over a ~200ms debounce window; plus two
//!           sentinel lines the server understands:
//!             `!fallback <reason>` — this root cannot be watched sanely
//!                (pathological root, dir budget exceeded); poll instead.
//!             `!error <reason>`    — fatal watch failure (inotify budget
//!                exhausted, unreadable root); printed just before exit(1).
//!
//! Watch registration is manual, one NonRecursive watch per directory,
//! walked from the root: excluded trees (node_modules, _build, …) are
//! skipped at REGISTRATION time, so they consume zero inotify descriptors
//! instead of merely being muted. Directories that appear later (mkdir,
//! whole trees renamed in) are registered dynamically from their create
//! events. `.git` is special-cased: the `.git` dir itself, index, and refs/
//! stay watched so staging and HEAD/branch switches surface; object/pack
//! churn does not.
//!
//! Exclusion matches path components RELATIVE to the root — a project that
//! itself lives under some `target/` or `node_modules/` still reports.

use std::collections::HashSet;
use std::io::{BufRead, Write};
use std::path::{Component, Path, PathBuf};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use notify::{RecommendedWatcher, RecursiveMode, Watcher};

const DEBOUNCE: Duration = Duration::from_millis(200);

/// Upper bound on watched directories per root. A walk that hits it is a
/// pathological root (monorepo of monorepos, $HOME-like) — degrade to
/// polling rather than eat the system's inotify budget. Overridable for
/// tests via DALA_WATCH_DIR_BUDGET.
const DEFAULT_DIR_BUDGET: usize = 30_000;

fn dir_budget() -> usize {
    std::env::var("DALA_WATCH_DIR_BUDGET")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_DIR_BUDGET)
}

/// Directory names whose subtrees are never watched or reported. Kept to
/// unambiguous machine-generated trees — a name like `dist` is too often
/// real content.
const EXCLUDED_DIRS: &[&str] = &[
    "node_modules",
    "_build",
    "deps",
    "target",
    ".venv",
    "venv",
    "__pycache__",
    ".cache",
    ".next",
    ".turbo",
    ".elixir_ls",
    ".pytest_cache",
    ".mypy_cache",
    ".hex",
    ".mix",
];

/// Whether a path — RELATIVE to the watch root — is ignored. Any excluded
/// component mutes it; under `.git`, only HEAD, index and refs/ stay audible.
/// Matching on the relative path keeps a root that itself lives inside an
/// excluded-name dir (a drawer rooted in node_modules) fully audible.
pub fn excluded(rel: &Path) -> bool {
    let comps: Vec<&str> = rel
        .components()
        .filter_map(|c| match c {
            Component::Normal(os) => os.to_str(),
            _ => None,
        })
        .collect();

    for (i, comp) in comps.iter().enumerate() {
        if EXCLUDED_DIRS.contains(comp) {
            return true;
        }
        if *comp == ".git" {
            let rest = &comps[i + 1..];
            let audible =
                rest.is_empty() || rest[0] == "HEAD" || rest[0] == "index" || rest[0] == "refs";
            if !audible {
                return true;
            }
        }
    }
    false
}

/// `path` relative to `root`; the path itself when it isn't under the root
/// (shouldn't happen — watches only exist under the root).
fn relative<'a>(path: &'a Path, root: &Path) -> &'a Path {
    path.strip_prefix(root).unwrap_or(path)
}

/// The directory whose listing an event at `path` invalidates.
fn affected_dir(path: &Path, root: &Path) -> PathBuf {
    if path == root {
        root.to_path_buf()
    } else {
        path.parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| root.to_path_buf())
    }
}

/// Roots that must never be watched recursively: a filesystem root and the
/// user's home itself.
/// Compared canonicalized so symlinked spellings don't slip through.
fn pathological_root(root: &Path) -> Option<&'static str> {
    let canon = root.canonicalize().ok()?;
    if canon.parent().is_none() || canon.parent() == Some(canon.as_path()) {
        return Some("root is a filesystem root");
    }
    if let Some(home) = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")) {
        if let Ok(home) = PathBuf::from(home).canonicalize() {
            if same_path(&canon, &home) {
                return Some("root is $HOME");
            }
        }
    }
    None
}

#[cfg(windows)]
fn same_path(left: &Path, right: &Path) -> bool {
    left.to_string_lossy()
        .eq_ignore_ascii_case(&right.to_string_lossy())
}

#[cfg(not(windows))]
fn same_path(left: &Path, right: &Path) -> bool {
    left == right
}

/// Sentinel lines share stdout with the change reports; a single locked
/// writeln keeps them line-atomic against the debounce thread.
fn emit_sentinel(line: &str) {
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

pub fn run() -> ! {
    let (tx, rx) = mpsc::channel::<PathBuf>();

    // Debounce + emit thread: batches dirs for DEBOUNCE, then prints each
    // once. A failed write means the BEAM is gone — exit.
    std::thread::spawn(move || {
        let stdout = std::io::stdout();
        loop {
            let Ok(first) = rx.recv() else { return };
            let mut batch: HashSet<PathBuf> = HashSet::new();
            batch.insert(first);
            let deadline = Instant::now() + DEBOUNCE;
            while let Some(left) = deadline.checked_duration_since(Instant::now()) {
                match rx.recv_timeout(left) {
                    Ok(dir) => {
                        batch.insert(dir);
                    }
                    Err(_) => break,
                }
            }
            let mut out = stdout.lock();
            for dir in &batch {
                if writeln!(out, "{}", dir.display()).is_err() {
                    std::process::exit(0);
                }
            }
            if out.flush().is_err() {
                std::process::exit(0);
            }
        }
    });

    // Main thread: root per stdin line; EOF => exit (the orphan guarantee).
    // `_current` is the keep-alive handle for the active watcher: dropping
    // it (on root replacement) tears every watch down AND disconnects the
    // manager thread's event channel, so the manager exits too. The
    // assignments are never *read* — ownership is the point — hence the
    // underscore.
    let stdin = std::io::stdin();
    let mut _current: Option<Arc<Mutex<RecommendedWatcher>>> = None;
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let root = PathBuf::from(line.trim());
        if root.as_os_str().is_empty() {
            continue;
        }

        _current = None;

        if !root.is_dir() {
            // Tolerable: the drawer can navigate somewhere that just got
            // deleted; the next root replaces us anyway.
            eprintln!("dala_holder watch: {}: not a directory", root.display());
            continue;
        }
        if let Some(reason) = pathological_root(&root) {
            emit_sentinel(&format!("!fallback {reason}"));
            continue;
        }

        let (raw_tx, raw_rx) = mpsc::channel::<Result<notify::Event, notify::Error>>();
        let built =
            notify::recommended_watcher(move |result: Result<notify::Event, notify::Error>| {
                let _ = raw_tx.send(result);
            });
        let watcher = match built {
            Ok(w) => Arc::new(Mutex::new(w)),
            Err(error) => {
                eprintln!("dala_holder watch: {error}");
                continue;
            }
        };

        // The manager holds only a Weak: the watcher (which owns the event
        // callback, which owns raw_tx) dies with `_current`, unblocking the
        // manager's recv — no reference cycle, no leaked watches.
        let weak = Arc::downgrade(&watcher);
        _current = Some(watcher);
        let out = tx.clone();
        std::thread::spawn(move || manage_root(root, weak, raw_rx, out));
    }

    std::process::exit(0);
}

/// Why (or that) tree registration stopped.
enum Register {
    /// Dir budget exhausted — pathological root, degrade to polling.
    Budget,
    /// Unrecoverable watch failure (inotify limits, unreadable root).
    Fatal(String),
    /// The root was replaced mid-walk; nothing to do.
    Gone,
}

/// Owns one root for its lifetime: registers the initial tree, then loops
/// on raw watcher events — reporting affected dirs and dynamically
/// registering directories that appear later. Exits when the watcher is
/// dropped (root replaced / process exiting).
fn manage_root(
    root: PathBuf,
    watcher: Weak<Mutex<RecommendedWatcher>>,
    raw: mpsc::Receiver<Result<notify::Event, notify::Error>>,
    out: mpsc::Sender<PathBuf>,
) {
    let budget = dir_budget();
    let mut registered = 0usize;

    match register_tree(&watcher, &root, &root, &mut registered, budget) {
        Ok(()) => {}
        Err(Register::Budget) => {
            emit_sentinel(&format!("!fallback dir budget exceeded ({budget})"));
            return;
        }
        Err(Register::Fatal(reason)) => {
            emit_sentinel(&format!("!error {reason}"));
            std::process::exit(1);
        }
        Err(Register::Gone) => return,
    }

    // Ready marker: anything that changed between the client listing the
    // root and this point was missed — reporting the root once makes the
    // client re-list and catch up.
    let _ = out.send(root.clone());

    // recv disconnects when the watcher (owner of the sending callback) is
    // dropped by the main thread — root replaced or process exiting.
    while let Ok(result) = raw.recv() {
        match result {
            Ok(event) => {
                if !relevant(&event.kind) {
                    continue;
                }
                for path in &event.paths {
                    if excluded(relative(path, &root)) {
                        continue;
                    }
                    let _ = out.send(affected_dir(path, &root));

                    // NEW directories (mkdir, or whole trees renamed in)
                    // need their own watches — walk and register, same
                    // exclusions, same budget.
                    if spawns_dirs(&event.kind) && path.is_dir() {
                        match register_tree(&watcher, &root, path, &mut registered, budget) {
                            Ok(()) => {}
                            Err(Register::Budget) => {
                                emit_sentinel(&format!("!fallback dir budget exceeded ({budget})"));
                                return;
                            }
                            Err(Register::Fatal(reason)) => {
                                emit_sentinel(&format!("!error {reason}"));
                                std::process::exit(1);
                            }
                            Err(Register::Gone) => return,
                        }
                    }
                }
            }
            // Backend hiccup (e.g. inotify queue overflow): report the
            // root so the client refreshes what it shows.
            Err(_) => {
                let _ = out.send(root.clone());
            }
        }
    }
}

/// Walks `start` (which must be under — or be — `root`) and registers one
/// NonRecursive watch per directory, skipping excluded subtrees entirely.
/// Watch-then-list per directory: children created during the walk are
/// caught either by the fresh watch (create event) or by the listing.
fn register_tree(
    watcher: &Weak<Mutex<RecommendedWatcher>>,
    root: &Path,
    start: &Path,
    registered: &mut usize,
    budget: usize,
) -> Result<(), Register> {
    let mut stack = vec![start.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if excluded(relative(&dir, root)) {
            continue;
        }
        if *registered >= budget {
            return Err(Register::Budget);
        }
        // Upgrade per dir: a long walk aborts promptly when the root is
        // replaced (main dropped the strong Arc).
        let Some(strong) = watcher.upgrade() else {
            return Err(Register::Gone);
        };
        let outcome = strong
            .lock()
            .unwrap()
            .watch(&dir, RecursiveMode::NonRecursive);
        drop(strong);
        match outcome {
            Ok(()) => *registered += 1,
            Err(error) => {
                if fatal_watch_error(&error) {
                    return Err(Register::Fatal(format!("{}: {error}", dir.display())));
                }
                if dir == root && !root.is_dir() {
                    // Root vanished before/while we walked — tolerable, the
                    // next stdin root replaces us.
                    eprintln!("dala_holder watch: {}: {error}", root.display());
                    return Ok(());
                }
                if dir == root {
                    // Any other failure to watch the root itself leaves us
                    // completely blind — that's fatal, degrade loudly.
                    return Err(Register::Fatal(format!("{}: {error}", dir.display())));
                }
                // A subdir vanished mid-walk or is unreadable: skip its
                // subtree, the rest of the tree still works.
                continue;
            }
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            // file_type() does not follow symlinks: symlinked trees can
            // neither loop the walk nor multiply watches.
            if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                stack.push(entry.path());
            }
        }
    }
    Ok(())
}

/// Watch errors that no retry or skip can fix: the kernel's inotify budget
/// (ENOSPC = max_user_watches, EMFILE = max_user_instances) — continuing
/// would just fail for every remaining dir while eating what's left.
fn fatal_watch_error(error: &notify::Error) -> bool {
    if matches!(error.kind, notify::ErrorKind::MaxFilesWatch) {
        return true;
    }
    if let notify::ErrorKind::Io(io) = &error.kind {
        return matches!(io.raw_os_error(), Some(libc::ENOSPC) | Some(libc::EMFILE));
    }
    false
}

/// Event kinds that can introduce new directories needing registration:
/// plain creates and rename-ins (a whole tree moved into the root arrives
/// as a single rename event for its top dir).
fn spawns_dirs(kind: &notify::EventKind) -> bool {
    use notify::event::{EventKind, ModifyKind};
    matches!(
        kind,
        EventKind::Create(_)
            | EventKind::Modify(ModifyKind::Name(_))
            | EventKind::Any
            | EventKind::Other
    )
}

/// Event kinds that change what a directory listing shows. Access events
/// (reads/opens) are noise — except close-after-write, which is how content
/// saves surface on inotify.
fn relevant(kind: &notify::EventKind) -> bool {
    use notify::event::{AccessKind, AccessMode, EventKind};
    match kind {
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(_) => true,
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
        EventKind::Access(_) => false,
        EventKind::Any | EventKind::Other => true,
    }
}

#[cfg(test)]
mod excluded_tests {
    use super::*;

    // excluded() takes paths RELATIVE to the watch root.

    #[test]
    fn plain_project_paths_are_audible() {
        assert!(!excluded(Path::new("lib/foo.ex")));
        assert!(!excluded(Path::new("")));
    }

    #[test]
    fn machine_generated_trees_are_muted_at_any_depth() {
        assert!(excluded(Path::new("node_modules/a/b.js")));
        assert!(excluded(Path::new("sub/node_modules")));
        assert!(excluded(Path::new("_build/test/lib")));
        assert!(excluded(Path::new("deps/phoenix/mix.exs")));
        assert!(excluded(Path::new("target/release/bin")));
        assert!(excluded(Path::new(".venv/lib/python")));
        assert!(excluded(Path::new("__pycache__/m.pyc")));
    }

    #[test]
    fn similarly_named_real_dirs_are_not_muted() {
        assert!(!excluded(Path::new("my_node_modules/x")));
        assert!(!excluded(Path::new("depsy/x")));
        assert!(!excluded(Path::new("lib/targets.ex")));
    }

    #[test]
    fn git_head_index_and_refs_are_audible_object_churn_is_not() {
        assert!(!excluded(Path::new(".git")));
        assert!(!excluded(Path::new(".git/HEAD")));
        assert!(!excluded(Path::new(".git/refs/heads/main")));
        assert!(excluded(Path::new(".git/objects/ab/cdef")));
        assert!(!excluded(Path::new(".git/index")));
        assert!(excluded(Path::new(".git/logs/HEAD")));
    }

    #[test]
    fn exclusion_is_relative_to_the_root() {
        // A root living INSIDE an excluded-name dir: events under it are
        // audible because matching starts below the root.
        let root = Path::new("/home/x/work/node_modules/proj");
        let event = root.join("src/main.rs");
        assert!(!excluded(relative(&event, root)));
        // …while the project's own excluded trees still mute.
        let nested = root.join("node_modules/dep/x.js");
        assert!(excluded(relative(&nested, root)));
    }

    #[test]
    fn affected_dir_is_the_parent_except_for_the_root_itself() {
        let root = Path::new("/p");
        assert_eq!(
            affected_dir(Path::new("/p/a/b.txt"), root),
            Path::new("/p/a")
        );
        assert_eq!(affected_dir(Path::new("/p/a"), root), Path::new("/p"));
        assert_eq!(affected_dir(root, root), Path::new("/p"));
    }
}
