defmodule Dala.Terminal.AgentCommands do
  @moduledoc """
  Slash-command catalog for the composer.

  None of the agent CLIs expose a programmatic "list slash commands" surface
  (built-ins live inside their TUIs), so the catalog is assembled from the
  sources that actually exist on disk:

  1. **Built-in tables** — data files in `priv/agent_commands/<agent>.json`,
     curated from each agent's official docs. Data, not code, so they can be
     refreshed without touching the module.
  2. **User overlays** — `<data_dir>/agent_commands/<agent>.json` (global)
     and a project's `dala.jsonc` `"agentCommands": {"<agent>": [...]}`.
     When a CLI update adds commands before dala ships a new table, the user
     (or an agent) patches the list locally; overlay entries override
     built-ins with the same name, and a `"hidden": true` entry removes a
     command from the menu.
  3. **Custom command/skill/prompt files** — the same files the CLIs read:
     `.claude/commands|skills` + plugin cache, `~/.codex/prompts`,
     opencode's `command` directories. Descriptions come from frontmatter.
  """

  def list(agent, cwd, locale \\ "en")

  def list(agent, cwd, locale) when agent in ~w(claude opencode codex gemini) do
    root = project_root(cwd)
    lang = lang(locale)

    # Precedence: user overlays > built-in tables > scanned files (a custom
    # file named like a built-in does not shadow it — same as the CLIs).
    # Dedup BEFORE dropping hidden entries so an overlay can hide a built-in.
    (overlays(agent, root) ++ builtins(agent) ++ scanned(agent, root))
    |> Enum.uniq_by(& &1.name)
    |> Enum.reject(& &1[:hidden])
    |> Enum.map(&%{name: &1.name, description: localize(&1.description, lang)})
    |> Enum.sort_by(& &1.name)
  end

  def list(_, _, _), do: []

  # UI locale → table language: only zh has its own column today, every
  # other locale reads the English one.
  defp lang(locale) when is_binary(locale) do
    if String.starts_with?(locale, "zh"), do: "zh", else: "en"
  end

  defp lang(_), do: "en"

  # Table entries carry %{"en" => _, "zh" => _}; overlay/frontmatter entries
  # may be plain strings (used as-is for every locale).
  defp localize(%{} = translations, lang) do
    to_string(
      translations[lang] || translations["en"] || translations |> Map.values() |> List.first() ||
        ""
    )
  end

  defp localize(description, _lang), do: to_string(description)

  # ---- 1. built-in tables (priv data) --------------------------------------

  defp builtins(agent) do
    path = Path.join(:code.priv_dir(:dala), "agent_commands/#{agent}.json")

    with {:ok, body} <- File.read(path),
         {:ok, rows} when is_list(rows) <- Jason.decode(body) do
      normalize(rows)
    else
      _ -> []
    end
  end

  # ---- 2. user overlays -----------------------------------------------------

  # Global overlay: <data_dir>/agent_commands/<agent>.json, same row format
  # as the priv tables (plus optional "hidden": true).
  defp overlays(agent, root) do
    global =
      :dala
      |> Application.fetch_env!(:data_dir)
      |> Path.expand()
      |> Path.join("agent_commands/#{agent}.json")
      |> read_rows()

    project = dala_jsonc_commands(agent, root)

    project ++ global
  end

  # Project overlay: dala.jsonc `"agentCommands": {"claude": [{...}]}`.
  defp dala_jsonc_commands(agent, root) do
    config_file =
      Dala.Paths.walk_up(root, fn dir ->
        path = Path.join(dir, "dala.jsonc")
        if File.regular?(path), do: path
      end)

    with path when is_binary(path) <- config_file,
         {:ok, body} <- File.read(path),
         {:ok, config} <- Jason.decode(Dala.Jsonc.strip(body)),
         %{"agentCommands" => %{^agent => rows}} when is_list(rows) <- config do
      normalize(rows)
    else
      _ -> []
    end
  end

  defp read_rows(path) do
    with {:ok, body} <- File.read(path),
         {:ok, rows} when is_list(rows) <- Jason.decode(body) do
      normalize(rows)
    else
      _ -> []
    end
  end

  defp normalize(rows) do
    for %{"name" => "/" <> _ = name} = row <- rows do
      %{name: name, description: truncate(row["description"]), hidden: row["hidden"] == true}
    end
  end

  defp truncate(%{} = translations) do
    Map.new(translations, fn {k, v} -> {k, String.slice(to_string(v), 0, 120)} end)
  end

  defp truncate(description), do: String.slice(to_string(description || ""), 0, 120)

  # ---- 3. on-disk custom commands (what the CLIs themselves read) ----------

  defp scanned("claude", root) do
    command_files(home(".claude/commands")) ++
      command_files(Path.join(root, ".claude/commands")) ++
      skills(home(".claude/skills")) ++
      skills(Path.join(root, ".claude/skills")) ++
      plugin_commands()
  end

  defp scanned("opencode", root) do
    command_files(home(".config/opencode/command")) ++
      command_files(home(".config/opencode/commands")) ++
      command_files(Path.join(root, ".opencode/command")) ++
      command_files(Path.join(root, ".opencode/commands"))
  end

  defp scanned("codex", root) do
    command_files(home(".codex/prompts")) ++
      command_files(Path.join(root, ".codex/prompts"))
  end

  defp scanned(_, _root), do: []

  defp home(rel), do: Dala.Paths.home(rel)

  # Custom commands live where the project starts, not necessarily the cwd.
  defp project_root(cwd), do: Dala.Paths.git_toplevel(cwd) || cwd

  # commands/a.md → /a; commands/git/pr.md → /git:pr (Claude's namespacing).
  defp command_files(dir) do
    for path <- Path.wildcard(Path.join([dir, "**", "*.md"])) do
      name =
        "/" <>
          (path
           |> Path.relative_to(dir)
           |> String.replace_suffix(".md", "")
           |> String.replace(["/", "\\"], ":"))

      %{name: name, description: frontmatter_description(path)}
    end
  end

  # skills/name.md and skills/name/SKILL.md both define skill "name".
  defp skills(dir) do
    flat =
      for path <- Path.wildcard(Path.join([dir, "*.md"])) do
        %{name: "/" <> Path.basename(path, ".md"), description: frontmatter_description(path)}
      end

    nested =
      for path <- Path.wildcard(Path.join([dir, "*", "SKILL.md"])) do
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
      for path <- Path.wildcard(Path.join([cache, "*", "commands", "**", "*.md"])) do
        %{name: "/" <> Path.basename(path, ".md"), description: frontmatter_description(path)}
      end

    plugin_skills =
      for path <- Path.wildcard(Path.join([cache, "*", "skills", "*", "SKILL.md"])) do
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
