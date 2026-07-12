defmodule Dala.Terminal.GitOps do
  @moduledoc """
  Git operations backing the git panel, implemented with libgit2 (via the
  `Dala.Git` Rust NIF) rather than shelling out to the `git` binary.

  Every function takes a path anywhere inside a repository; the repository
  root is discovered automatically.
  """

  @file_at_max_bytes 2 * 1024 * 1024

  @doc """
  Working-tree status of the repository containing `path`.

  Returns `%{repo: false, ...}` when the path is not inside a git work tree.
  File statuses are porcelain `XY` codes (`" M"`, `"M "`, `"??"`, `"R "`, …).
  """
  def status(path) do
    case Dala.Git.status(expand(path)) do
      {:ok, result} -> result
      {:error, _reason} -> %{repo: false, root: nil, branch: nil, files: []}
    end
  end

  @doc "Unified diff of one file against HEAD (untracked files show as added)."
  def diff(path, file) do
    case Dala.Git.diff_file(expand(path), file) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Full contents of one file at a revision, for the merge diff view.

  `rev` is anything libgit2 revparse accepts (`HEAD`, a sha, `sha^`, …); the
  special `"WORKTREE"` reads the file from disk instead.
  """
  def file_at(path, "WORKTREE", file) do
    root = repo_root(path)

    case File.read(Path.join(root, file)) do
      {:ok, content} ->
        cond do
          not String.valid?(content) or String.contains?(content, <<0>>) ->
            {:ok, %{content: "", binary: true, truncated: false, missing: false}}

          byte_size(content) > @file_at_max_bytes ->
            {:ok,
             %{
               content: Dala.Utf8.truncate(content, @file_at_max_bytes),
               binary: false,
               truncated: true,
               missing: false
             }}

          true ->
            {:ok, %{content: content, binary: false, truncated: false, missing: false}}
        end

      {:error, _reason} ->
        {:ok, %{content: "", binary: false, truncated: false, missing: true}}
    end
  end

  def file_at(path, rev, file), do: Dala.Git.file_at(expand(path), rev, file)

  # The worktree read needs the repo root: file paths in diffs are
  # root-relative, while `path` may point anywhere inside the repo.
  defp repo_root(path) do
    case Dala.Git.status(expand(path)) do
      {:ok, %{root: root}} when is_binary(root) -> root
      _other -> expand(path)
    end
  end

  @doc "Amend HEAD with the current index (empty message keeps the original)."
  def commit_amend(path, message), do: Dala.Git.commit_amend(expand(path), message)

  @doc """
  Apply a unified patch to the index (stage/unstage a hunk) or the working
  tree (discard a hunk). The caller builds the patch already reversed when it
  wants an undo direction.
  """
  def apply_patch(path, patch, target) when target in [:index, :workdir] do
    case Dala.Git.apply_patch(expand(path), patch, target == :index) do
      {:ok, _applied} -> {:ok, %{applied: true}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stage one file."
  def stage(path, file), do: unwrap(Dala.Git.stage(expand(path), file))

  @doc "Unstage one file, keeping worktree changes."
  def unstage(path, file), do: unwrap(Dala.Git.unstage(expand(path), file))

  @doc "Discard all changes to one file (untracked files are deleted)."
  def discard(path, file), do: unwrap(Dala.Git.discard(expand(path), file))

  @doc "Commit the staged changes. Returns the new short hash."
  def commit(path, message) when is_binary(message) do
    case Dala.Git.commit(expand(path), message) do
      {:ok, %{hash: hash}} -> {:ok, %{hash: hash}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Recent commits, newest first."
  def log(path, limit \\ 50) do
    case Dala.Git.log(expand(path), limit) do
      {:ok, %{commits: commits}} ->
        {:ok, %{commits: Enum.map(commits, &format_commit/1)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Full patch of one commit."
  def show(path, hash) do
    with :ok <- validate_hash(hash),
         {:ok, result} <- Dala.Git.show(expand(path), hash) do
      {:ok, result}
    end
  end

  @doc "Local and remote branches, plus the currently checked-out branch."
  def branches(path) do
    case Dala.Git.branches(expand(path)) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Check out (switch to) a local branch, or a remote branch as a new tracking branch."
  def checkout(path, name), do: unwrap(Dala.Git.checkout(expand(path), name))

  ## Helpers

  defp unwrap({:ok, _}), do: {:ok, true}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp format_commit(%{hash: hash, author: author, subject: subject, date_unix: unix}) do
    %{
      hash: hash,
      author: author,
      subject: subject,
      date: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()
    }
  end

  defp validate_hash(hash) do
    if hash =~ ~r/^[0-9a-fA-F]{4,64}$/, do: :ok, else: {:error, "invalid commit hash"}
  end

  defp expand(path), do: Dala.Paths.expand_user(path)
end
