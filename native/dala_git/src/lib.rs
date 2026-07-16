use std::path::Path;

use git2::build::CheckoutBuilder;
use git2::{
    BranchType, DiffFormat, DiffOptions, ErrorCode, IndexAddOption, Repository, Status,
    StatusOptions,
};
use rustler::NifMap;

const MAX_DIFF_BYTES: usize = 512 * 1024;
const MAX_FILE_AT_BYTES: usize = 2 * 1024 * 1024;

#[derive(NifMap)]
struct FileStatus {
    path: String,
    status: String,
    staged: bool,
    unstaged: bool,
}

#[derive(NifMap)]
struct StatusResult {
    repo: bool,
    root: Option<String>,
    branch: Option<String>,
    files: Vec<FileStatus>,
    ignored: Vec<String>,
}

#[derive(NifMap)]
struct DiffResult {
    diff: String,
    binary: bool,
    truncated: bool,
}

#[derive(NifMap)]
struct FileAtResult {
    content: String,
    binary: bool,
    truncated: bool,
    missing: bool,
}

#[derive(NifMap)]
struct Commit {
    hash: String,
    author: String,
    date_unix: i64,
    subject: String,
}

#[derive(NifMap)]
struct LogResult {
    commits: Vec<Commit>,
}

#[derive(NifMap)]
struct ShowResult {
    text: String,
    truncated: bool,
}

#[derive(NifMap)]
struct CommitResult {
    hash: String,
}

#[derive(NifMap)]
struct Branch {
    name: String,
    current: bool,
}

#[derive(NifMap)]
struct BranchesResult {
    current: Option<String>,
    local: Vec<Branch>,
    remote: Vec<Branch>,
}

fn git_error(err: git2::Error) -> String {
    err.message().to_string()
}

fn open(path: &str) -> Result<Repository, String> {
    Repository::discover(path).map_err(|_| format!("not a git repository: {path}"))
}

/// Largest valid-UTF-8 prefix that fits in `max` bytes.
fn truncate_utf8(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

// --- status -----------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn status(path: String) -> Result<StatusResult, String> {
    let repo = match Repository::discover(&path) {
        Ok(repo) => repo,
        Err(_) => {
            return Ok(StatusResult {
                repo: false,
                root: None,
                branch: None,
                files: vec![],
                ignored: vec![],
            })
        }
    };

    let root = repo
        .workdir()
        .map(|p| p.to_string_lossy().trim_end_matches('/').to_string());

    let branch = match repo.head() {
        Ok(head) if head.is_branch() => head.shorthand().map(|s| s.to_string()),
        Ok(_) => Some("HEAD".to_string()),
        Err(_) => None,
    };

    let mut opts = StatusOptions::new();
    opts.include_untracked(true)
        .recurse_untracked_dirs(true)
        .include_ignored(true)
        // Return an ignored directory as one entry. Recursing through build
        // output or dependency trees would make a status refresh unbounded.
        .recurse_ignored_dirs(false);

    let statuses = repo.statuses(Some(&mut opts)).map_err(git_error)?;
    let mut files = Vec::new();
    let mut ignored = Vec::new();

    for entry in statuses.iter() {
        let Some(path) = entry.path() else { continue };
        let s = entry.status();
        if s.is_ignored() {
            ignored.push(path.trim_end_matches('/').to_string());
            continue;
        }
        let (code, staged, unstaged) = porcelain(s);
        files.push(FileStatus {
            path: path.to_string(),
            status: code,
            staged,
            unstaged,
        });
    }

    files.sort_by(|a, b| a.path.cmp(&b.path));
    ignored.sort();
    ignored.dedup();

    Ok(StatusResult {
        repo: true,
        root,
        branch,
        files,
        ignored,
    })
}

/// Porcelain `XY` status code plus staged/unstaged flags for one entry. A
/// file with both index and worktree changes (e.g. `MM`) is both, and shows
/// up in both lists like Fork does.
fn porcelain(s: Status) -> (String, bool, bool) {
    if s.contains(Status::CONFLICTED) {
        return ("UU".to_string(), false, true);
    }

    // Untracked: only a working-tree "new" bit.
    if s.contains(Status::WT_NEW) && !has_index_change(s) {
        return ("??".to_string(), false, true);
    }

    let x = if s.contains(Status::INDEX_NEW) {
        'A'
    } else if s.contains(Status::INDEX_MODIFIED) {
        'M'
    } else if s.contains(Status::INDEX_DELETED) {
        'D'
    } else if s.contains(Status::INDEX_RENAMED) {
        'R'
    } else if s.contains(Status::INDEX_TYPECHANGE) {
        'T'
    } else {
        ' '
    };

    let y = if s.contains(Status::WT_MODIFIED) {
        'M'
    } else if s.contains(Status::WT_DELETED) {
        'D'
    } else if s.contains(Status::WT_RENAMED) {
        'R'
    } else if s.contains(Status::WT_TYPECHANGE) {
        'T'
    } else {
        ' '
    };

    (format!("{x}{y}"), x != ' ', y != ' ')
}

fn has_index_change(s: Status) -> bool {
    s.intersects(
        Status::INDEX_NEW
            | Status::INDEX_MODIFIED
            | Status::INDEX_DELETED
            | Status::INDEX_RENAMED
            | Status::INDEX_TYPECHANGE,
    )
}

// --- diff -------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn diff_file(path: String, file: String, staged: bool) -> Result<DiffResult, String> {
    let repo = open(&path)?;

    let mut opts = DiffOptions::new();
    opts.pathspec(&file)
        .include_untracked(true)
        .recurse_untracked_dirs(true)
        .show_untracked_content(true);

    // Match the perspective the diff view renders each hunk against (the
    // CmDiff sides), so the counts, hunk headers and fallback rows line up:
    //   * unstaged ("changes"): index ↔ workdir
    //   * staged:               HEAD  ↔ index
    // A combined HEAD ↔ workdir diff (the old behaviour) only agrees with
    // those when the file has no changes on the OTHER side; a file that is
    // both staged AND modified (`MM`) otherwise renders additions as red
    // deletions with mismatched line numbers.
    let index = repo.index().map_err(git_error)?;
    let diff = if staged {
        let head_tree = repo.head().ok().and_then(|h| h.peel_to_tree().ok());
        repo.diff_tree_to_index(head_tree.as_ref(), Some(&index), Some(&mut opts))
            .map_err(git_error)?
    } else {
        repo.diff_index_to_workdir(Some(&index), Some(&mut opts))
            .map_err(git_error)?
    };

    let (text, binary) = format_diff(&diff)?;
    let truncated = text.len() > MAX_DIFF_BYTES;

    Ok(DiffResult {
        diff: truncate_utf8(&text, MAX_DIFF_BYTES),
        binary,
        truncated,
    })
}

/// Amend HEAD with the current index; an empty message keeps the original.
#[rustler::nif(schedule = "DirtyCpu")]
fn commit_amend(path: String, message: String) -> Result<CommitResult, String> {
    let repo = open(&path)?;

    let mut index = repo.index().map_err(git_error)?;
    let tree_id = index.write_tree().map_err(git_error)?;
    let tree = repo.find_tree(tree_id).map_err(git_error)?;

    let head = repo
        .head()
        .and_then(|h| h.peel_to_commit())
        .map_err(git_error)?;

    let message = if message.trim().is_empty() {
        head.message().unwrap_or("").to_string()
    } else {
        message
    };

    let oid = head
        .amend(Some("HEAD"), None, None, None, Some(&message), Some(&tree))
        .map_err(git_error)?;

    Ok(CommitResult {
        hash: short_hash(&oid.to_string()),
    })
}

/// Apply a unified patch to the index (stage/unstage a hunk) or the working
/// tree (discard a hunk). Reversal is the caller's job: it builds the patch
/// in the direction it wants applied.
#[rustler::nif(schedule = "DirtyCpu")]
fn apply_patch(path: String, patch: String, to_index: bool) -> Result<bool, String> {
    let repo = open(&path)?;
    let diff = git2::Diff::from_buffer(patch.as_bytes()).map_err(git_error)?;

    let location = if to_index {
        git2::ApplyLocation::Index
    } else {
        git2::ApplyLocation::WorkDir
    };

    repo.apply(&diff, location, None).map_err(git_error)?;

    if to_index {
        repo.index()
            .and_then(|mut index| index.write())
            .map_err(git_error)?;
    }

    Ok(true)
}

/// Full contents of one file at a revision (`HEAD`, a sha, `sha^`, …), for
/// the syntax-highlighted merge diff view. A missing path (new/deleted file,
/// bad rev) is reported as `missing`, not an error.
#[rustler::nif(schedule = "DirtyCpu")]
fn file_at(path: String, rev: String, file: String) -> Result<FileAtResult, String> {
    let repo = open(&path)?;

    let missing = FileAtResult {
        content: String::new(),
        binary: false,
        truncated: false,
        missing: true,
    };

    // ":0" (the index) is git-CLI revision syntax that libgit2's revparse
    // does not understand — read the staged blob straight from the index.
    let blob = if rev == ":0" {
        let index = match repo.index() {
            Ok(index) => index,
            Err(_) => return Ok(missing),
        };
        match index
            .get_path(Path::new(&file), 0)
            .and_then(|entry| repo.find_blob(entry.id).ok())
        {
            Some(blob) => blob,
            None => return Ok(missing),
        }
    } else {
        let spec = format!("{rev}:{file}");
        match repo.revparse_single(&spec).and_then(|o| o.peel_to_blob()) {
            Ok(blob) => blob,
            Err(_) => return Ok(missing),
        }
    };

    if blob.is_binary() {
        return Ok(FileAtResult {
            content: String::new(),
            binary: true,
            truncated: false,
            missing: false,
        });
    }

    match std::str::from_utf8(blob.content()) {
        Ok(text) => Ok(FileAtResult {
            content: truncate_utf8(text, MAX_FILE_AT_BYTES),
            binary: false,
            truncated: text.len() > MAX_FILE_AT_BYTES,
            missing: false,
        }),
        // Not valid UTF-8: treat like binary so the caller falls back.
        Err(_) => Ok(FileAtResult {
            content: String::new(),
            binary: true,
            truncated: false,
            missing: false,
        }),
    }
}

fn format_diff(diff: &git2::Diff) -> Result<(String, bool), String> {
    let mut buf = String::new();
    let mut binary = false;

    diff.print(DiffFormat::Patch, |delta, _hunk, line| {
        if delta.flags().is_binary() {
            binary = true;
        }
        match line.origin() {
            '+' | '-' | ' ' => buf.push(line.origin()),
            _ => {}
        }
        buf.push_str(&String::from_utf8_lossy(line.content()));
        true
    })
    .map_err(git_error)?;

    Ok((buf, binary))
}

// --- staging ----------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn stage(path: String, file: String) -> Result<bool, String> {
    let repo = open(&path)?;
    let mut index = repo.index().map_err(git_error)?;
    // add_all mirrors `git add <pathspec>`: stages additions, modifications
    // and deletions of matching files.
    index
        .add_all([&file].iter(), IndexAddOption::DEFAULT, None)
        .map_err(git_error)?;
    index.write().map_err(git_error)?;
    Ok(true)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn unstage(path: String, file: String) -> Result<bool, String> {
    let repo = open(&path)?;

    match repo.head().and_then(|h| h.peel_to_commit()) {
        Ok(head) => {
            repo.reset_default(Some(head.as_object()), [&file])
                .map_err(git_error)?;
        }
        Err(_) => {
            // No commits yet: unstaging just removes the entry from the index.
            let mut index = repo.index().map_err(git_error)?;
            index.remove_path(Path::new(&file)).map_err(git_error)?;
            index.write().map_err(git_error)?;
        }
    }

    Ok(true)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn discard(path: String, file: String) -> Result<bool, String> {
    let repo = open(&path)?;
    let head_tree = repo.head().ok().and_then(|h| h.peel_to_tree().ok());

    let tracked = head_tree
        .as_ref()
        .map(|tree| tree.get_path(Path::new(&file)).is_ok())
        .unwrap_or(false);

    if tracked {
        let tree = head_tree.unwrap();
        let mut co = CheckoutBuilder::new();
        co.force().update_index(true).path(&file);
        repo.checkout_tree(tree.as_object(), Some(&mut co))
            .map_err(git_error)?;
    } else {
        let full = repo
            .workdir()
            .ok_or_else(|| "bare repository".to_string())?
            .join(&file);
        std::fs::remove_file(&full).map_err(|e| format!("could not delete {file}: {e}"))?;
    }

    Ok(true)
}

// --- commit -----------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn commit(path: String, message: String) -> Result<CommitResult, String> {
    let repo = open(&path)?;
    let sig = repo
        .signature()
        .map_err(|_| "no git identity configured (user.name / user.email)".to_string())?;

    let mut index = repo.index().map_err(git_error)?;
    let tree_oid = index.write_tree().map_err(git_error)?;
    let tree = repo.find_tree(tree_oid).map_err(git_error)?;

    let parent = repo.head().ok().and_then(|h| h.peel_to_commit().ok());

    // Reject empty commits (nothing staged).
    match &parent {
        Some(p) if p.tree_id() == tree_oid => {
            return Err("nothing to commit — working tree clean".to_string())
        }
        None if tree.is_empty() => return Err("nothing to commit".to_string()),
        _ => {}
    }

    let parents: Vec<&git2::Commit> = parent.iter().collect();
    let oid = repo
        .commit(Some("HEAD"), &sig, &sig, &message, &tree, &parents)
        .map_err(git_error)?;

    Ok(CommitResult {
        hash: short_hash(&oid.to_string()),
    })
}

fn short_hash(hash: &str) -> String {
    hash.chars().take(7).collect()
}

// --- log / show -------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn log(path: String, limit: usize) -> Result<LogResult, String> {
    let repo = open(&path)?;

    let mut revwalk = match repo.revwalk() {
        Ok(rw) => rw,
        Err(_) => return Ok(LogResult { commits: vec![] }),
    };

    if revwalk.push_head().is_err() {
        // Empty repository (unborn HEAD).
        return Ok(LogResult { commits: vec![] });
    }

    let mut commits = Vec::new();
    for oid in revwalk.take(limit) {
        let oid = oid.map_err(git_error)?;
        let c = repo.find_commit(oid).map_err(git_error)?;
        commits.push(Commit {
            hash: short_hash(&oid.to_string()),
            author: c.author().name().unwrap_or("").to_string(),
            date_unix: c.time().seconds(),
            subject: c.summary().unwrap_or("").to_string(),
        });
    }

    Ok(LogResult { commits })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn show(path: String, hash: String) -> Result<ShowResult, String> {
    let repo = open(&path)?;
    let commit = repo
        .revparse_single(&hash)
        .and_then(|o| o.peel_to_commit())
        .map_err(|_| format!("no such commit: {hash}"))?;

    let mut text = String::new();
    text.push_str(&format!("commit {}\n", commit.id()));
    text.push_str(&format!(
        "Author: {} <{}>\n",
        commit.author().name().unwrap_or(""),
        commit.author().email().unwrap_or("")
    ));
    text.push('\n');
    for line in commit.message().unwrap_or("").lines() {
        text.push_str("    ");
        text.push_str(line);
        text.push('\n');
    }
    text.push('\n');

    let tree = commit.tree().map_err(git_error)?;
    let parent_tree = commit.parent(0).ok().and_then(|p| p.tree().ok());
    let diff = repo
        .diff_tree_to_tree(parent_tree.as_ref(), Some(&tree), None)
        .map_err(git_error)?;

    let (patch, _binary) = format_diff(&diff)?;
    text.push_str(&patch);

    let truncated = text.len() > MAX_DIFF_BYTES;

    Ok(ShowResult {
        text: truncate_utf8(&text, MAX_DIFF_BYTES),
        truncated,
    })
}

// --- branches ---------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn branches(path: String) -> Result<BranchesResult, String> {
    let repo = open(&path)?;

    let current = match repo.head() {
        Ok(head) if head.is_branch() => head.shorthand().map(|s| s.to_string()),
        _ => None,
    };

    let mut local = Vec::new();
    let mut remote = Vec::new();

    let iter = repo.branches(None).map_err(git_error)?;
    for item in iter {
        let (branch, kind) = item.map_err(git_error)?;
        let Some(name) = branch.name().map_err(git_error)?.map(|s| s.to_string()) else {
            continue;
        };
        match kind {
            BranchType::Local => local.push(Branch {
                current: branch.is_head(),
                name,
            }),
            BranchType::Remote => {
                // Skip symbolic refs like "origin/HEAD".
                if !name.ends_with("/HEAD") {
                    remote.push(Branch {
                        name,
                        current: false,
                    });
                }
            }
        }
    }

    local.sort_by(|a, b| a.name.cmp(&b.name));
    remote.sort_by(|a, b| a.name.cmp(&b.name));

    Ok(BranchesResult {
        current,
        local,
        remote,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn checkout(path: String, name: String) -> Result<bool, String> {
    let repo = open(&path)?;

    // Existing local branch → plain switch.
    let local_ref = format!("refs/heads/{name}");
    if repo.find_reference(&local_ref).is_ok() {
        switch_to(&repo, &name, &local_ref)?;
        return Ok(true);
    }

    // Remote-tracking branch (e.g. "origin/feature") → create/switch a local
    // branch that tracks it, like `git switch feature`.
    if let Ok(remote_ref) = repo.find_reference(&format!("refs/remotes/{name}")) {
        let commit = remote_ref.peel_to_commit().map_err(git_error)?;
        let local_name = name.splitn(2, '/').nth(1).unwrap_or(&name).to_string();

        if repo.find_branch(&local_name, BranchType::Local).is_err() {
            let mut b = repo
                .branch(&local_name, &commit, false)
                .map_err(git_error)?;
            let _ = b.set_upstream(Some(&name));
        }

        switch_to(&repo, &local_name, &format!("refs/heads/{local_name}"))?;
        return Ok(true);
    }

    Err(format!("branch not found: {name}"))
}

fn switch_to(repo: &Repository, revspec: &str, ref_name: &str) -> Result<(), String> {
    let (object, _reference) = repo.revparse_ext(revspec).map_err(git_error)?;

    // Safe checkout: refuses to overwrite conflicting local modifications.
    let mut co = CheckoutBuilder::new();
    co.safe();
    repo.checkout_tree(&object, Some(&mut co)).map_err(|e| {
        if e.code() == ErrorCode::Conflict {
            "your local changes would be overwritten — commit or discard them first".to_string()
        } else {
            git_error(e)
        }
    })?;

    repo.set_head(ref_name).map_err(git_error)?;
    Ok(())
}

rustler::init!("Elixir.Dala.Git");
