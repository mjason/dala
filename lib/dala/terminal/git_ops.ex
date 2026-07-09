defmodule Dala.Terminal.GitOps do
  @moduledoc """
  Git operations backing the git panel, implemented with libgit2 (via the
  `Dala.Git` Rust NIF) rather than shelling out to the `git` binary.

  Every function takes a path anywhere inside a repository; the repository
  root is discovered automatically.
  """

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

  defp expand("~" <> rest), do: Path.expand((System.user_home() || "/") <> rest)
  defp expand(path), do: Path.expand(path)
end
