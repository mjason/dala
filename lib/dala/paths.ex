defmodule Dala.Paths do
  @moduledoc """
  Filesystem path helpers shared across the app: `~` expansion, `$HOME`-relative
  paths, git-toplevel discovery and upward directory walks.

  Everything here resolves `$HOME` at RUNTIME, never compile time — releases
  are built on CI where `$HOME` is not the user's.
  """

  @doc """
  Expands a path to an absolute one, treating a leading `~` as the user's
  home directory (falling back to `/` when `$HOME` is unset).
  """
  def expand_user("~" <> rest), do: Path.expand((System.user_home() || "/") <> rest)
  def expand_user(path), do: Path.expand(path)

  @doc "A path under the user's home directory (or `/` when `$HOME` is unset)."
  def home(rel), do: Path.join(System.user_home() || "/", rel)

  @doc """
  The toplevel of the git work tree containing `dir`, or `nil` when the
  directory is outside any repository (or `git` itself is unavailable).
  """
  def git_toplevel(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Walks from `dir` upward through its ancestors, calling `fun` on each
  directory; the first truthy result is returned. Returns `nil` once the git
  toplevel, `$HOME` or the filesystem root has been checked without a match
  (the stop directory itself IS checked).
  """
  def walk_up(dir, fun) when is_function(fun, 1) do
    top = git_toplevel(dir)
    home = System.user_home()

    Stream.iterate(dir, &Path.dirname/1)
    |> Enum.reduce_while(nil, fn current, _acc ->
      cond do
        result = fun.(current) ->
          {:halt, result}

        current == top or current == home or Path.dirname(current) == current ->
          {:halt, nil}

        true ->
          {:cont, nil}
      end
    end)
  end
end
