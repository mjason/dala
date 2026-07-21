defmodule Dala.Terminal.GitOpsTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.GitOps

  setup do
    dir = Path.join(System.tmp_dir!(), "dala-git-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "test@dala.dev"])
    git!(dir, ["config", "user.name", "Dala Test"])
    git!(dir, ["config", "core.autocrlf", "false"])

    File.write!(Path.join(dir, "a.txt"), "line one\nline two\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "init"])

    %{dir: dir}
  end

  defp git!(dir, args) do
    {_out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
  end

  test "status reports branch and clean tree", %{dir: dir} do
    assert %{repo: true, branch: "main", files: [], ignored: []} = GitOps.status(dir)
  end

  test "status reports modified, staged and untracked files", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "line one CHANGED\nline two\n")
    File.write!(Path.join(dir, "new.txt"), "fresh\n")
    File.write!(Path.join(dir, "staged.txt"), "staged content\n")
    git!(dir, ["add", "staged.txt"])

    %{repo: true, files: files} = GitOps.status(dir)
    by_path = Map.new(files, &{&1.path, &1})

    assert %{status: " M", staged: false} = by_path["a.txt"]
    assert %{status: "??", staged: false} = by_path["new.txt"]
    assert %{status: "A ", staged: true} = by_path["staged.txt"]
  end

  test "status works from a subdirectory and reports the repo root", %{dir: dir} do
    sub = Path.join(dir, "nested/deep")
    File.mkdir_p!(sub)

    assert %{repo: true, root: root} = GitOps.status(sub)
    # macOS/WSL tmp dirs may involve symlinks; compare the basename
    assert Path.basename(root) == Path.basename(dir)
  end

  test "status outside a repository", %{dir: _dir} do
    assert %{repo: false, files: [], ignored: []} = GitOps.status(System.tmp_dir!())
  end

  test "status separates ignored paths without recursing ignored directories", %{dir: dir} do
    File.write!(Path.join(dir, ".gitignore"), "cache/\nignored.log\n")
    File.mkdir_p!(Path.join(dir, "cache/deep"))
    File.write!(Path.join(dir, "cache/deep/value.bin"), "x")
    File.write!(Path.join(dir, "ignored.log"), "x")

    assert %{ignored: ["cache", "ignored.log"], files: files} = GitOps.status(dir)
    refute Enum.any?(files, &(&1.path in ["cache", "ignored.log"]))
  end

  test "diff of a modified tracked file", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "line one CHANGED\nline two\n")

    assert {:ok, %{diff: diff, binary: false, truncated: false}} = GitOps.diff(dir, "a.txt")
    assert diff =~ "-line one"
    assert diff =~ "+line one CHANGED"
  end

  test "staged view diffs HEAD↔index; the unstaged view of the same file is empty", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "totally new\n")
    git!(dir, ["add", "a.txt"])

    # Staged view (HEAD ↔ index) shows the staged change.
    assert {:ok, %{diff: staged}} = GitOps.diff(dir, "a.txt", true)
    assert staged =~ "+totally new"

    # Unstaged view (index ↔ workdir): nothing on top of the index.
    assert {:ok, %{diff: unstaged}} = GitOps.diff(dir, "a.txt", false)
    refute unstaged =~ "totally new"
  end

  test "a file that is both staged AND modified splits cleanly by perspective", %{dir: dir} do
    # HEAD: 2 lines. Stage a 4-line rewrite, then delete one of those lines in
    # the working tree without re-staging → git status `MM`. This is the case
    # that used to render additions as red deletions with wrong line numbers
    # (the diff text was HEAD↔workdir while the merge view was index↔workdir).
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree\nfour\n")
    git!(dir, ["add", "a.txt"])
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree\n")

    # Unstaged view = index (4 lines) ↔ workdir (3 lines): only the `four`
    # deletion, and NOT the staged additions.
    assert {:ok, %{diff: unstaged}} = GitOps.diff(dir, "a.txt", false)
    assert unstaged =~ "-four"
    refute unstaged =~ "+three"

    # Staged view = HEAD (2 lines) ↔ index (4 lines): the staged additions,
    # and NOT the working-tree deletion.
    assert {:ok, %{diff: staged}} = GitOps.diff(dir, "a.txt", true)
    assert staged =~ "+three"
    assert staged =~ "+four"
  end

  test "diff of an untracked file shows it as fully added", %{dir: dir} do
    File.write!(Path.join(dir, "new.txt"), "alpha\nbeta\n")

    assert {:ok, %{diff: diff, binary: false}} = GitOps.diff(dir, "new.txt")
    assert diff =~ "+alpha"
    assert diff =~ "+beta"
  end

  test "diff flags binary files", %{dir: dir} do
    File.write!(Path.join(dir, "blob.bin"), <<0, 1, 2, 255, 254>>)

    assert {:ok, %{binary: true}} = GitOps.diff(dir, "blob.bin")
  end

  test "diff outside a repository errors" do
    assert {:error, message} = GitOps.diff(System.tmp_dir!(), "whatever.txt")
    assert message =~ "not a git repository"
  end

  test "stage and unstage a file", %{dir: dir} do
    File.write!(Path.join(dir, "new.txt"), "fresh\n")

    assert {:ok, true} = GitOps.stage(dir, "new.txt")
    assert %{files: [%{path: "new.txt", status: "A ", staged: true}]} = GitOps.status(dir)

    assert {:ok, true} = GitOps.unstage(dir, "new.txt")
    assert %{files: [%{path: "new.txt", status: "??", staged: false}]} = GitOps.status(dir)
  end

  test "discard restores a tracked file and deletes an untracked one", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "mangled\n")
    File.write!(Path.join(dir, "junk.txt"), "junk\n")

    assert {:ok, true} = GitOps.discard(dir, "a.txt")
    assert File.read!(Path.join(dir, "a.txt")) == "line one\nline two\n"

    assert {:ok, true} = GitOps.discard(dir, "junk.txt")
    refute File.exists?(Path.join(dir, "junk.txt"))
    assert %{files: []} = GitOps.status(dir)
  end

  test "commit commits the staged changes only", %{dir: dir} do
    File.write!(Path.join(dir, "staged.txt"), "in the commit\n")
    File.write!(Path.join(dir, "unstaged.txt"), "left behind\n")
    {:ok, true} = GitOps.stage(dir, "staged.txt")

    assert {:ok, %{hash: hash}} = GitOps.commit(dir, "add staged.txt")
    assert hash =~ ~r/^[0-9a-f]{4,}$/

    %{files: files} = GitOps.status(dir)
    assert [%{path: "unstaged.txt", status: "??"}] = files
  end

  test "commit with nothing staged errors", %{dir: dir} do
    assert {:error, message} = GitOps.commit(dir, "empty")
    assert message =~ ~r/nothing|clean/i
  end

  test "log lists commits newest first and show returns the patch", %{dir: dir} do
    File.write!(Path.join(dir, "b.txt"), "second file\n")
    {:ok, true} = GitOps.stage(dir, "b.txt")
    {:ok, %{hash: hash}} = GitOps.commit(dir, "second commit")

    assert {:ok, %{commits: [newest, oldest]}} = GitOps.log(dir)
    assert newest.subject == "second commit"
    assert newest.hash == hash
    assert oldest.subject == "init"
    assert newest.author == "Dala Test"

    assert {:ok, %{text: text, truncated: false}} = GitOps.show(dir, hash)
    assert text =~ "second commit"
    assert text =~ "+second file"
  end

  test "show rejects malformed hashes", %{dir: dir} do
    assert {:error, message} = GitOps.show(dir, "--output=/tmp/evil")
    assert message =~ "invalid commit hash"
  end

  test "branches lists local branches and the current one", %{dir: dir} do
    git!(dir, ["branch", "feature"])
    git!(dir, ["branch", "bugfix"])

    assert {:ok, %{current: "main", local: local, remote: []}} = GitOps.branches(dir)
    names = Enum.map(local, & &1.name) |> Enum.sort()
    assert names == ["bugfix", "feature", "main"]
    assert Enum.find(local, &(&1.name == "main")).current
    refute Enum.find(local, &(&1.name == "feature")).current
  end

  test "checkout switches the current branch", %{dir: dir} do
    git!(dir, ["branch", "feature"])

    assert {:ok, true} = GitOps.checkout(dir, "feature")
    assert %{branch: "feature"} = GitOps.status(dir)

    assert {:ok, true} = GitOps.checkout(dir, "main")
    assert %{branch: "main"} = GitOps.status(dir)
  end

  test "checkout refuses to clobber conflicting local changes", %{dir: dir} do
    # a.txt differs between branches; a dirty worktree edit conflicts
    git!(dir, ["checkout", "-q", "-b", "other"])
    File.write!(Path.join(dir, "a.txt"), "other-branch version\n")
    git!(dir, ["commit", "-q", "-am", "change on other"])
    git!(dir, ["checkout", "-q", "main"])

    File.write!(Path.join(dir, "a.txt"), "uncommitted local edit\n")

    assert {:error, message} = GitOps.checkout(dir, "other")
    assert message =~ "local changes"
    # still on main, edit preserved
    assert %{branch: "main"} = GitOps.status(dir)
    assert File.read!(Path.join(dir, "a.txt")) == "uncommitted local edit\n"
  end

  test "checkout of an unknown branch errors", %{dir: dir} do
    assert {:error, message} = GitOps.checkout(dir, "does-not-exist")
    assert message =~ "not found"
  end
end
