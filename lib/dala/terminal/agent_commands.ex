defmodule Dala.Terminal.AgentCommands do
  @moduledoc """
  Slash-command catalog for the composer: the agents' built-ins plus what is
  actually installed on this machine — user/project custom commands, skills
  and plugin commands. The agents' own completion menus need per-keystroke
  TUI input, so the composer builds its own list from disk.
  """

  @claude_builtins ~w(
    /add-dir /agents /bashes /bug /clear /compact /config /context /cost
    /doctor /export /help /hooks /init /install-github-app /login /logout
    /mcp /memory /model /output-style /permissions /plugin /pr-comments
    /release-notes /resume /review /rewind /statusline /status /terminal-setup
    /todos /usage /vim
  )

  @opencode_builtins ~w(
    /compact /editor /exit /help /init /models /new /redo /sessions /share
    /theme /undo
  )

  @codex_builtins ~w(
    /approvals /compact /diff /init /logout /mcp /mention /model /new /quit
    /review /status
  )

  @gemini_builtins ~w(
    /about /auth /chat /clear /compress /copy /docs /help /mcp /memory
    /quit /stats /theme /tools
  )

  def list("claude", cwd) do
    root = project_root(cwd)

    (@claude_builtins ++
       command_files(home(".claude/commands")) ++
       command_files(Path.join(root, ".claude/commands")) ++
       skills(home(".claude/skills")) ++
       skills(Path.join(root, ".claude/skills")) ++
       plugin_commands())
    |> Enum.uniq()
    |> Enum.sort()
  end

  def list("opencode", cwd) do
    root = project_root(cwd)

    (@opencode_builtins ++
       command_files(home(".config/opencode/command")) ++
       command_files(home(".config/opencode/commands")) ++
       command_files(Path.join(root, ".opencode/command")) ++
       command_files(Path.join(root, ".opencode/commands")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  def list("codex", _cwd), do: @codex_builtins
  def list("gemini", _cwd), do: @gemini_builtins
  def list(_, _), do: []

  defp home(rel), do: Path.join(System.user_home() || "/", rel)

  # Custom commands live where the project starts, not necessarily the cwd.
  defp project_root(cwd) do
    case System.cmd("git", ["-C", cwd, "rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> cwd
    end
  rescue
    _ -> cwd
  end

  # commands/a.md → /a; commands/git/pr.md → /git:pr (Claude's namespacing).
  defp command_files(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*.md")) do
      "/" <>
        (path
         |> Path.relative_to(dir)
         |> String.replace_suffix(".md", "")
         |> String.replace("/", ":"))
    end
  end

  # skills/name.md and skills/name/SKILL.md both define skill "name".
  defp skills(dir) do
    flat =
      for path <- Path.wildcard(Path.join(dir, "*.md")),
          do: "/" <> Path.basename(path, ".md")

    nested =
      for path <- Path.wildcard(Path.join(dir, "*/SKILL.md")),
          do: "/" <> (path |> Path.dirname() |> Path.basename())

    flat ++ nested
  end

  defp plugin_commands do
    command_files_glob = Path.join(home(".claude/plugins/cache"), "*/commands/**/*.md")

    plugin_skills =
      for path <- Path.wildcard(Path.join(home(".claude/plugins/cache"), "*/skills/*/SKILL.md")),
          do: "/" <> (path |> Path.dirname() |> Path.basename())

    commands =
      for path <- Path.wildcard(command_files_glob) do
        "/" <> (path |> Path.basename(".md"))
      end

    commands ++ plugin_skills
  end
end
