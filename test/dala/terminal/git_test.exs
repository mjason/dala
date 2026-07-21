defmodule Dala.Terminal.GitTest do
  @moduledoc """
  Tests for the `Dala.Terminal.Git` Ash resource — the generic actions that
  back the git panel (status/diff/stage/unstage/discard/commit, hunk-level
  staging via patches, log/show/branches/checkout).

  Each test gets its own throwaway repository under the system tmp dir with
  one initial commit of `a.txt`.
  """

  use ExUnit.Case, async: true

  @initial_content "line one\nline two\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "dala-git-action-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "test@dala.dev"])
    git!(dir, ["config", "user.name", "Dala Test"])
    git!(dir, ["config", "core.autocrlf", "false"])

    File.write!(Path.join(dir, "a.txt"), @initial_content)
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "init"])

    %{dir: dir}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp run!(action, args) do
    Dala.Terminal.Git
    |> Ash.ActionInput.for_action(action, args)
    |> Ash.run_action!()
  end

  defp run(action, args) do
    Dala.Terminal.Git
    |> Ash.ActionInput.for_action(action, args)
    |> Ash.run_action()
  end

  # Split a unified diff into its header and the individual "@@ …" hunks so a
  # test can build a partial patch, exactly like the git panel client does.
  defp split_hunks(diff) do
    [header | hunks] = String.split(diff, ~r/(?=^@@ )/m)
    {header, hunks}
  end

  describe "git_status" do
    test "clean repository reports branch and no files", %{dir: dir} do
      assert %{repo: true, branch: "main", root: root, files: [], ignored: []} =
               run!(:git_status, %{path: dir})

      assert Path.basename(root) == Path.basename(dir)
    end

    test "reports modified, untracked and staged files with porcelain codes", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "line one CHANGED\nline two\n")
      File.write!(Path.join(dir, "new.txt"), "fresh\n")
      File.write!(Path.join(dir, "staged.txt"), "staged content\n")
      git!(dir, ["add", "staged.txt"])

      assert %{repo: true, files: files} = run!(:git_status, %{path: dir})
      by_path = Map.new(files, &{&1.path, &1})

      assert %{status: " M", staged: false, unstaged: true} = by_path["a.txt"]
      assert %{status: "??", staged: false, unstaged: true} = by_path["new.txt"]
      assert %{status: "A ", staged: true, unstaged: false} = by_path["staged.txt"]
    end

    test "a file that is both staged and modified again is flagged on both sides", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "staged version\n")
      git!(dir, ["add", "a.txt"])
      File.write!(Path.join(dir, "a.txt"), "worktree version\n")

      assert %{files: [%{path: "a.txt", status: "MM", staged: true, unstaged: true}]} =
               run!(:git_status, %{path: dir})
    end

    test "reports ignored files and collapsed ignored directories separately", %{dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "ignored.txt\nbuild/\n")
      File.write!(Path.join(dir, "ignored.txt"), "ignored\n")
      File.mkdir_p!(Path.join(dir, "build/nested"))
      File.write!(Path.join(dir, "build/nested/output.bin"), "ignored\n")

      assert %{files: files, ignored: ignored} = run!(:git_status, %{path: dir})
      assert Enum.sort(ignored) == ["build", "ignored.txt"]
      refute Enum.any?(files, &(&1.path in ignored))
      refute Enum.any?(ignored, &String.starts_with?(&1, "build/"))
    end

    test "works from a nested subdirectory of the repo", %{dir: dir} do
      sub = Path.join(dir, "nested/deep")
      File.mkdir_p!(sub)

      assert %{repo: true, branch: "main"} = run!(:git_status, %{path: sub})
    end

    test "a path outside any repository reports repo: false instead of erroring" do
      outside =
        Path.join(System.tmp_dir!(), "dala-git-norepo-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      assert %{repo: false, root: nil, branch: nil, files: [], ignored: []} =
               run!(:git_status, %{path: outside})
    end
  end

  describe "git_diff" do
    test "modified tracked file diffs against HEAD", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "line one CHANGED\nline two\n")

      assert %{diff: diff, binary: false, truncated: false} =
               run!(:git_diff, %{path: dir, file: "a.txt"})

      assert diff =~ "-line one"
      assert diff =~ "+line one CHANGED"
    end

    test "the staged view diffs HEAD↔index; the unstaged view of it is empty", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "totally new\n")
      git!(dir, ["add", "a.txt"])

      # staged: true → HEAD ↔ index shows the staged rewrite.
      assert %{diff: staged} = run!(:git_diff, %{path: dir, file: "a.txt", staged: true})
      assert staged =~ "+totally new"
      assert staged =~ "-line one"

      # default (unstaged) → index ↔ workdir: nothing on top of the index.
      assert %{diff: unstaged} = run!(:git_diff, %{path: dir, file: "a.txt"})
      refute unstaged =~ "totally new"
    end

    test "untracked file shows as fully added", %{dir: dir} do
      File.write!(Path.join(dir, "new.txt"), "alpha\nbeta\n")

      assert %{diff: diff, binary: false} = run!(:git_diff, %{path: dir, file: "new.txt"})
      assert diff =~ "+alpha"
      assert diff =~ "+beta"
    end

    test "binary files are flagged instead of diffed", %{dir: dir} do
      File.write!(Path.join(dir, "blob.bin"), <<0, 1, 2, 255, 254>>)

      assert %{binary: true} = run!(:git_diff, %{path: dir, file: "blob.bin"})
    end

    test "outside a repository the action errors" do
      assert {:error, error} = run(:git_diff, %{path: System.tmp_dir!(), file: "x.txt"})
      assert Exception.message(error) =~ "not a git repository"
    end
  end

  describe "git_file_at" do
    test "HEAD returns the committed content", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "changed on disk\n")

      assert %{content: @initial_content, binary: false, truncated: false, missing: false} =
               run!(:git_file_at, %{path: dir, rev: "HEAD", file: "a.txt"})
    end

    test "WORKTREE returns the on-disk content", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "changed on disk\n")

      assert %{content: "changed on disk\n", missing: false} =
               run!(:git_file_at, %{path: dir, rev: "WORKTREE", file: "a.txt"})
    end

    test "index content is visible via the staged revision after committing", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "v2\n")
      git!(dir, ["add", "a.txt"])
      git!(dir, ["commit", "-q", "-m", "v2"])

      assert %{content: "v2\n"} = run!(:git_file_at, %{path: dir, rev: "HEAD", file: "a.txt"})

      assert %{content: @initial_content} =
               run!(:git_file_at, %{path: dir, rev: "HEAD^", file: "a.txt"})
    end

    test "a file missing from the worktree reports missing: true", %{dir: dir} do
      assert %{content: "", missing: true, binary: false} =
               run!(:git_file_at, %{path: dir, rev: "WORKTREE", file: "nope.txt"})
    end

    test "binary worktree files are flagged and not returned", %{dir: dir} do
      File.write!(Path.join(dir, "blob.bin"), <<0, 1, 2, 255>>)

      assert %{content: "", binary: true} =
               run!(:git_file_at, %{path: dir, rev: "WORKTREE", file: "blob.bin"})
    end

    test "an unknown revision reports the file as missing", %{dir: dir} do
      assert %{content: "", missing: true} =
               run!(:git_file_at, %{path: dir, rev: "no-such-rev", file: "a.txt"})
    end
  end

  describe "git_stage / git_unstage" do
    test "stage then unstage a new file round-trips through the index", %{dir: dir} do
      File.write!(Path.join(dir, "new.txt"), "fresh\n")

      assert true == run!(:git_stage, %{path: dir, file: "new.txt"})

      assert %{files: [%{path: "new.txt", status: "A ", staged: true}]} =
               run!(:git_status, %{path: dir})

      assert true == run!(:git_unstage, %{path: dir, file: "new.txt"})

      assert %{files: [%{path: "new.txt", status: "??", staged: false}]} =
               run!(:git_status, %{path: dir})
    end

    test "staging a modification keeps the worktree content", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "modified\n")

      assert true == run!(:git_stage, %{path: dir, file: "a.txt"})

      assert %{files: [%{path: "a.txt", status: "M ", staged: true, unstaged: false}]} =
               run!(:git_status, %{path: dir})

      assert File.read!(Path.join(dir, "a.txt")) == "modified\n"
    end

    test "unstaging keeps the worktree changes", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "modified\n")
      git!(dir, ["add", "a.txt"])

      assert true == run!(:git_unstage, %{path: dir, file: "a.txt"})

      assert %{files: [%{path: "a.txt", status: " M", staged: false, unstaged: true}]} =
               run!(:git_status, %{path: dir})

      assert File.read!(Path.join(dir, "a.txt")) == "modified\n"
    end
  end

  describe "git_discard" do
    test "restores a tracked file to its HEAD content", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "mangled\n")

      assert true == run!(:git_discard, %{path: dir, file: "a.txt"})
      assert File.read!(Path.join(dir, "a.txt")) == @initial_content
      assert %{files: []} = run!(:git_status, %{path: dir})
    end

    test "deletes an untracked file", %{dir: dir} do
      File.write!(Path.join(dir, "junk.txt"), "junk\n")

      assert true == run!(:git_discard, %{path: dir, file: "junk.txt"})
      refute File.exists?(Path.join(dir, "junk.txt"))
    end
  end

  describe "git_apply_patch" do
    # A file long enough that two edits far apart produce two separate hunks.
    defp write_two_hunk_file(dir) do
      lines = for n <- 1..20, do: "line #{n}"
      File.write!(Path.join(dir, "big.txt"), Enum.join(lines, "\n") <> "\n")
      git!(dir, ["add", "big.txt"])
      git!(dir, ["commit", "-q", "-m", "add big.txt"])

      changed =
        lines
        |> List.replace_at(0, "line 1 CHANGED")
        |> List.replace_at(19, "line 20 CHANGED")

      File.write!(Path.join(dir, "big.txt"), Enum.join(changed, "\n") <> "\n")
    end

    test "staging a single hunk leaves the other hunk unstaged", %{dir: dir} do
      write_two_hunk_file(dir)

      %{diff: diff} = run!(:git_diff, %{path: dir, file: "big.txt"})
      {header, [hunk1, hunk2]} = split_hunks(diff)
      assert hunk1 =~ "+line 1 CHANGED"
      assert hunk2 =~ "+line 20 CHANGED"

      assert %{applied: true} =
               run!(:git_apply_patch, %{path: dir, patch: header <> hunk1, target: :index})

      # partially staged: both index and worktree carry changes
      assert %{files: [%{path: "big.txt", status: "MM", staged: true, unstaged: true}]} =
               run!(:git_status, %{path: dir})

      # only hunk 1 made it into the index
      %{diff: staged_diff} =
        run!(:git_diff, %{path: dir, file: "big.txt", staged: true})

      assert staged_diff =~ "+line 1 CHANGED"
      refute staged_diff =~ "line 20 CHANGED"
    end

    test "applying the whole diff to the index stages the file fully", %{dir: dir} do
      File.write!(Path.join(dir, "a.txt"), "line one CHANGED\nline two\n")

      %{diff: diff} = run!(:git_diff, %{path: dir, file: "a.txt"})

      assert %{applied: true} =
               run!(:git_apply_patch, %{path: dir, patch: diff, target: :index})

      assert %{files: [%{path: "a.txt", status: "M ", staged: true, unstaged: false}]} =
               run!(:git_status, %{path: dir})
    end

    test "a reversed hunk applied to the workdir discards just that hunk", %{dir: dir} do
      write_two_hunk_file(dir)

      # The client sends patches already reversed for undo directions; the
      # test builds the reversed diff the same way (`git diff -R`).
      {reversed, 0} = System.cmd("git", ["-C", dir, "diff", "-R", "--", "big.txt"])
      {header, [hunk1, _hunk2]} = split_hunks(reversed)

      assert %{applied: true} =
               run!(:git_apply_patch, %{path: dir, patch: header <> hunk1, target: :workdir})

      content = File.read!(Path.join(dir, "big.txt"))
      refute content =~ "line 1 CHANGED"
      assert content =~ "line 20 CHANGED"
    end

    test "garbage patches error instead of applying", %{dir: dir} do
      assert {:error, _error} =
               run(:git_apply_patch, %{path: dir, patch: "this is not a patch\n", target: :index})
    end
  end

  describe "git_commit" do
    test "commits only the staged changes and returns the new hash", %{dir: dir} do
      File.write!(Path.join(dir, "staged.txt"), "in the commit\n")
      File.write!(Path.join(dir, "unstaged.txt"), "left behind\n")
      true = run!(:git_stage, %{path: dir, file: "staged.txt"})

      assert %{hash: hash} = run!(:git_commit, %{path: dir, message: "add staged.txt"})
      assert hash =~ ~r/^[0-9a-f]{4,}$/

      log = git!(dir, ["log", "--oneline"])
      assert log =~ "add staged.txt"
      assert log =~ hash

      assert %{files: [%{path: "unstaged.txt", status: "??"}]} =
               run!(:git_status, %{path: dir})
    end

    test "with nothing staged it fails gracefully", %{dir: dir} do
      assert {:error, error} = run(:git_commit, %{path: dir, message: "empty"})
      assert Exception.message(error) =~ ~r/nothing|clean/i
    end

    test "amend rewrites HEAD with the new message and staged content", %{dir: dir} do
      File.write!(Path.join(dir, "extra.txt"), "amended in\n")
      true = run!(:git_stage, %{path: dir, file: "extra.txt"})

      assert %{hash: hash} =
               run!(:git_commit, %{path: dir, message: "init, amended", amend: true})

      assert hash =~ ~r/^[0-9a-f]{4,}$/

      log = git!(dir, ["log", "--oneline"])
      # still a single commit, with the new subject
      assert length(String.split(String.trim(log), "\n")) == 1
      assert log =~ "init, amended"

      files = git!(dir, ["show", "--name-only", "--format=", "HEAD"])
      assert files =~ "extra.txt"
      assert files =~ "a.txt"
    end
  end

  describe "git_log" do
    test "lists commits newest first with author, date and subject", %{dir: dir} do
      File.write!(Path.join(dir, "b.txt"), "second file\n")
      true = run!(:git_stage, %{path: dir, file: "b.txt"})
      %{hash: hash} = run!(:git_commit, %{path: dir, message: "second commit"})

      assert %{commits: [newest, oldest]} = run!(:git_log, %{path: dir})
      assert newest.subject == "second commit"
      assert newest.hash == hash
      assert newest.author == "Dala Test"
      assert {:ok, _dt, _offset} = DateTime.from_iso8601(newest.date)
      assert oldest.subject == "init"
    end

    test "limit caps the number of commits returned", %{dir: dir} do
      for n <- 1..3 do
        File.write!(Path.join(dir, "f#{n}.txt"), "#{n}\n")
        true = run!(:git_stage, %{path: dir, file: "f#{n}.txt"})
        %{hash: _} = run!(:git_commit, %{path: dir, message: "commit #{n}"})
      end

      assert %{commits: commits} = run!(:git_log, %{path: dir, limit: 2})
      assert length(commits) == 2
      assert [%{subject: "commit 3"}, %{subject: "commit 2"}] = commits
    end
  end

  describe "git_show" do
    test "returns the full patch of one commit", %{dir: dir} do
      File.write!(Path.join(dir, "b.txt"), "second file\n")
      true = run!(:git_stage, %{path: dir, file: "b.txt"})
      %{hash: hash} = run!(:git_commit, %{path: dir, message: "second commit"})

      assert %{text: text, truncated: false} = run!(:git_show, %{path: dir, hash: hash})
      assert text =~ "second commit"
      assert text =~ "+second file"
    end

    test "rejects malformed hashes", %{dir: dir} do
      assert {:error, error} = run(:git_show, %{path: dir, hash: "--output=/tmp/evil"})
      assert Exception.message(error) =~ "invalid commit hash"
    end
  end

  describe "git_branches" do
    test "lists local branches and marks the current one", %{dir: dir} do
      git!(dir, ["branch", "feature"])

      assert %{current: "main", local: local, remote: []} = run!(:git_branches, %{path: dir})

      names = local |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["feature", "main"]
      assert Enum.find(local, &(&1.name == "main")).current
      refute Enum.find(local, &(&1.name == "feature")).current
    end
  end

  describe "git_checkout" do
    test "switches to another branch and back", %{dir: dir} do
      git!(dir, ["branch", "feature"])

      assert true == run!(:git_checkout, %{path: dir, name: "feature"})
      assert %{branch: "feature"} = run!(:git_status, %{path: dir})

      assert true == run!(:git_checkout, %{path: dir, name: "main"})
      assert %{branch: "main"} = run!(:git_status, %{path: dir})
    end

    test "an unknown branch errors", %{dir: dir} do
      assert {:error, error} = run(:git_checkout, %{path: dir, name: "does-not-exist"})
      assert Exception.message(error) =~ "not found"
    end
  end
end
