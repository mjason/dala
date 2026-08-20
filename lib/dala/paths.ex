defmodule Dala.Paths do
  @moduledoc """
  Filesystem path helpers shared across the app: `~` expansion, `$HOME`-relative
  paths, git-toplevel discovery and upward directory walks.

  Everything here resolves `$HOME` at RUNTIME, never compile time — releases
  are built on CI where `$HOME` is not the user's.
  """

  @git_toplevel_timeout_ms 10_000

  @doc """
  Expands a path to an absolute one, treating a leading `~` as the user's
  home directory (falling back to `/` when `$HOME` is unset).
  """
  def expand_user("~" <> rest), do: Path.expand((System.user_home() || "/") <> rest)
  def expand_user(path), do: Path.expand(path)

  @doc "A path under the user's home directory (or `/` when `$HOME` is unset)."
  def home(rel), do: Path.join(expand_user(System.user_home() || "/"), rel)

  @doc """
  The toplevel of the git work tree containing `dir`, or `nil` when the
  directory is outside any repository (or `git` itself is unavailable).
  """
  def git_toplevel(dir) do
    git = System.find_executable("git") || "git"

    case Dala.ShellPort.run(
           [git, "-C", dir, "rev-parse", "--show-cdup"],
           "/dev/null",
           @git_toplevel_timeout_ms
         ) do
      {:ok, out, 0} ->
        case String.trim(out) do
          "" -> Path.expand(dir)
          relative -> Path.expand(Path.join(dir, relative))
        end

      _ ->
        nil
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
    dir = expand_user(dir)
    top = git_toplevel(dir)
    home = System.user_home() && expand_user(System.user_home())

    Stream.iterate(dir, &Path.dirname/1)
    |> Enum.reduce_while(nil, fn current, _acc ->
      cond do
        result = fun.(current) ->
          {:halt, result}

        same_path?(current, top) or same_path?(current, home) or
            same_path?(Path.dirname(current), current) ->
          {:halt, nil}

        true ->
          {:cont, nil}
      end
    end)
  end

  defp same_path?(left, right) when is_binary(left) and is_binary(right) do
    canonical_path(left) == canonical_path(right)
  end

  defp same_path?(_left, _right), do: false

  defp canonical_path(path) do
    path = Path.expand(path)
    if Dala.Platform.windows?(), do: String.downcase(path), else: path
  end
end
