defmodule Dala.Terminal.AgentCommands do
  @moduledoc """
  Slash-command catalog for the composer: the agents' built-ins plus what is
  actually installed on this machine — user/project custom commands, skills
  and plugin commands (descriptions read from their frontmatter). The agents'
  own completion menus need per-keystroke TUI input, so the composer builds
  its own list from disk.
  """

  @claude_builtins [
    {"/add-dir", "Add a new working directory"},
    {"/agents", "Manage agent configurations"},
    {"/bashes", "List and manage background tasks"},
    {"/bug", "Submit feedback about Claude Code"},
    {"/clear", "Clear conversation history"},
    {"/compact", "Compact conversation history"},
    {"/config", "Open config panel"},
    {"/context", "Visualize current context usage"},
    {"/cost", "Show token usage and cost"},
    {"/doctor", "Diagnose installation issues"},
    {"/export", "Export conversation"},
    {"/help", "Show help and available commands"},
    {"/hooks", "Manage hook configurations"},
    {"/init", "Create a CLAUDE.md for this codebase"},
    {"/install-github-app", "Set up Claude GitHub Actions"},
    {"/login", "Sign in to your account"},
    {"/logout", "Sign out"},
    {"/mcp", "Manage MCP servers"},
    {"/memory", "Edit memory files"},
    {"/model", "Switch model"},
    {"/output-style", "Set the output style"},
    {"/permissions", "Manage tool permissions"},
    {"/plugin", "Manage plugins"},
    {"/pr-comments", "View pull request comments"},
    {"/release-notes", "Show release notes"},
    {"/resume", "Resume a previous conversation"},
    {"/review", "Review a pull request"},
    {"/rewind", "Rewind conversation and/or code"},
    {"/status", "Show session status"},
    {"/statusline", "Set up the status line"},
    {"/terminal-setup", "Configure terminal key bindings"},
    {"/todos", "List current todo items"},
    {"/usage", "Show plan usage limits"},
    {"/vim", "Toggle vim editing mode"}
  ]

  @opencode_builtins [
    {"/compact", "Compact the session"},
    {"/editor", "Open external editor"},
    {"/exit", "Exit opencode"},
    {"/help", "Show help"},
    {"/init", "Create AGENTS.md"},
    {"/models", "List available models"},
    {"/new", "Start a new session"},
    {"/redo", "Redo an undone message"},
    {"/sessions", "List sessions"},
    {"/share", "Share the session"},
    {"/theme", "Switch theme"},
    {"/undo", "Undo the last message"}
  ]

  @codex_builtins [
    {"/approvals", "Set approval mode"},
    {"/compact", "Compact the conversation"},
    {"/diff", "Show the current diff"},
    {"/init", "Create AGENTS.md"},
    {"/logout", "Sign out"},
    {"/mcp", "Manage MCP servers"},
    {"/mention", "Mention a file"},
    {"/model", "Switch model"},
    {"/new", "Start a new conversation"},
    {"/quit", "Exit Codex"},
    {"/review", "Review current changes"},
    {"/status", "Show session status"}
  ]

  @gemini_builtins [
    {"/about", "Version info"},
    {"/auth", "Change authentication method"},
    {"/chat", "Manage conversation state"},
    {"/clear", "Clear the screen"},
    {"/compress", "Compress context"},
    {"/copy", "Copy last output"},
    {"/docs", "Open documentation"},
    {"/help", "Show help"},
    {"/mcp", "Manage MCP servers"},
    {"/memory", "Manage memory"},
    {"/quit", "Exit Gemini CLI"},
    {"/stats", "Show session stats"},
    {"/theme", "Switch theme"},
    {"/tools", "List available tools"}
  ]

  def list("claude", cwd) do
    root = project_root(cwd)

    (builtins(@claude_builtins) ++
       command_files(home(".claude/commands")) ++
       command_files(Path.join(root, ".claude/commands")) ++
       skills(home(".claude/skills")) ++
       skills(Path.join(root, ".claude/skills")) ++
       plugin_commands())
    |> dedup_sort()
  end

  def list("opencode", cwd) do
    root = project_root(cwd)

    (builtins(@opencode_builtins) ++
       command_files(home(".config/opencode/command")) ++
       command_files(home(".config/opencode/commands")) ++
       command_files(Path.join(root, ".opencode/command")) ++
       command_files(Path.join(root, ".opencode/commands")))
    |> dedup_sort()
  end

  def list("codex", _cwd), do: builtins(@codex_builtins)
  def list("gemini", _cwd), do: builtins(@gemini_builtins)
  def list(_, _), do: []

  defp builtins(pairs),
    do: Enum.map(pairs, fn {name, desc} -> %{name: name, description: desc} end)

  defp dedup_sort(commands) do
    commands
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

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
      name =
        "/" <>
          (path
           |> Path.relative_to(dir)
           |> String.replace_suffix(".md", "")
           |> String.replace("/", ":"))

      %{name: name, description: frontmatter_description(path)}
    end
  end

  # skills/name.md and skills/name/SKILL.md both define skill "name".
  defp skills(dir) do
    flat =
      for path <- Path.wildcard(Path.join(dir, "*.md")) do
        %{name: "/" <> Path.basename(path, ".md"), description: frontmatter_description(path)}
      end

    nested =
      for path <- Path.wildcard(Path.join(dir, "*/SKILL.md")) do
        %{
          name: "/" <> (path |> Path.dirname() |> Path.basename()),
          description: frontmatter_description(path)
        }
      end

    flat ++ nested
  end

  defp plugin_commands do
    cache = home(".claude/plugins/cache")

    commands =
      for path <- Path.wildcard(Path.join(cache, "*/commands/**/*.md")) do
        %{name: "/" <> Path.basename(path, ".md"), description: frontmatter_description(path)}
      end

    plugin_skills =
      for path <- Path.wildcard(Path.join(cache, "*/skills/*/SKILL.md")) do
        %{
          name: "/" <> (path |> Path.dirname() |> Path.basename()),
          description: frontmatter_description(path)
        }
      end

    commands ++ plugin_skills
  end

  # The `description:` value from a leading YAML frontmatter block.
  defp frontmatter_description(path) do
    with {:ok, file} <- File.open(path, [:read, :utf8]),
         head = IO.read(file, 2048),
         :ok = File.close(file),
         true <- is_binary(head) and String.starts_with?(head, "---") do
      head
      |> String.split("\n")
      |> Enum.find_value("", fn line ->
        case String.split(line, "description:", parts: 2) do
          [_, value] -> value |> String.trim() |> String.trim("\"") |> String.slice(0, 120)
          _ -> nil
        end
      end)
    else
      _ -> ""
    end
  end
end
