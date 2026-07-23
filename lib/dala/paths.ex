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
  Returns an absolute path in the host platform's comparison form.

  Windows paths are case-insensitive and may arrive with either slash style,
  so comparison keys use forward slashes and lowercase. Unix paths preserve
  case.
  """
  def comparison_key(path) when is_binary(path) do
    path
    |> Path.expand()
    |> comparison_key_for_os(:os.type())
  end

  @doc false
  def comparison_key_for_os(path, os_type) when is_binary(path) do
    normalized = String.replace(path, "\\", "/")

    if match?({:win32, _}, os_type),
      do: simple_windows_case_key(normalized),
      else: normalized
  end

  # Windows' ordinal-ignore-case comparison uses a one-codepoint simple case
  # mapping. Full Unicode casing is intentionally avoided: for example, the
  # sharp-s character and SS are distinct filenames on Windows, while Greek
  # final sigma still collides with ordinary sigma. Some codepoints have a
  # multi-codepoint full uppercase mapping but a one-codepoint titlecase
  # mapping; use that titlecase value, then fold back to a simple lowercase
  # key so existing callers retain their lowercase comparison-key format.
  defp simple_windows_case_key(value) do
    if String.valid?(value) do
      for <<codepoint::utf8 <- value>>, into: <<>> do
        mapped = :unicode_util.get_case(codepoint)

        upper_or_title =
          case mapped do
            %{upper: value} when is_integer(value) -> value
            %{title: value} when is_integer(value) -> value
            _ -> codepoint
          end

        lower =
          case :unicode_util.get_case(upper_or_title) do
            %{lower: value} when is_integer(value) -> value
            _ -> upper_or_title
          end

        <<lower::utf8>>
      end
    else
      value
    end
  end

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

        git_boundary?(current, top) or same_path?(current, home) or
            same_path?(Path.dirname(current), current) ->
          {:halt, nil}

        true ->
          {:cont, nil}
      end
    end)
  end

  defp git_boundary?(path, top) do
    File.exists?(Path.join(path, ".git")) or same_path?(path, top)
  end

  defp same_path?(_path, nil), do: false

  defp same_path?(left, right) do
    comparison_key(left) == comparison_key(right)
  end
end
