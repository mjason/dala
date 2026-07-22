defmodule Dala.Terminal.AgentCommandsTest do
  # Reads real user-home command dirs alongside the temp project dir, so all
  # assertions are membership-based with unique names (never full-list equality).
  use ExUnit.Case, async: true

  alias Dala.Terminal.AgentCommands

  setup do
    cwd =
      Dala.TestPlatform.normalize_path(
        Path.join(System.tmp_dir!(), "agent-cmds-[literal]-#{System.unique_integer([:positive])}")
      )

    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf!(cwd) end)
    {:ok, cwd: cwd}
  end

  defp write_md(cwd, rel, content) do
    path = Path.join(cwd, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp find(commands, name), do: Enum.find(commands, &(&1.name == name))

  describe "project command files (claude)" do
    test "top-level file maps to /name with its frontmatter description", %{cwd: cwd} do
      write_md(cwd, ".claude/commands/dalatest-deploy.md", """
      ---
      description: Deploy the thing
      ---
      # body
      """)

      assert %{description: "Deploy the thing"} =
               find(AgentCommands.list("claude", cwd), "/dalatest-deploy")
    end

    test "nested files use Claude's colon namespacing (git/pr.md → /git:pr)", %{cwd: cwd} do
      write_md(cwd, ".claude/commands/dalatest-git/pr.md", """
      ---
      description: Open a pull request
      ---
      """)

      write_md(cwd, ".claude/commands/dalatest-git/deep/fix.md", "---\ndescription: x\n---\n")

      commands = AgentCommands.list("claude", cwd)

      assert %{description: "Open a pull request"} = find(commands, "/dalatest-git:pr")
      assert find(commands, "/dalatest-git:deep:fix")
    end

    test "a file without frontmatter gets an empty description", %{cwd: cwd} do
      write_md(cwd, ".claude/commands/dalatest-plain.md", """
      # Just a title

      description: this is body text, not frontmatter
      """)

      assert %{description: ""} = find(AgentCommands.list("claude", cwd), "/dalatest-plain")
    end

    test "does not traverse a directory symlink", %{cwd: cwd} do
      outside = Path.join(cwd, "outside-commands")
      write_md(outside, "dalatest-linked.md", "---\ndescription: linked\n---\n")

      link = Path.join(cwd, ".claude/commands/linked")
      File.mkdir_p!(Path.dirname(link))

      case File.ln_s(outside, link) do
        :ok ->
          refute find(AgentCommands.list("claude", cwd), "/linked:dalatest-linked")

        {:error, reason} ->
          if Dala.TestPlatform.windows?(),
            do: :ok,
            else: flunk("could not create directory symlink: #{inspect(reason)}")
      end
    end

    test "quoted descriptions are unquoted and long ones truncated to 120 chars", %{cwd: cwd} do
      write_md(cwd, ".claude/commands/dalatest-quoted.md", """
      ---
      description: "A quoted description"
      ---
      """)

      long = String.duplicate("x", 200)

      write_md(cwd, ".claude/commands/dalatest-long.md", """
      ---
      description: #{long}
      ---
      """)

      commands = AgentCommands.list("claude", cwd)

      assert %{description: "A quoted description"} = find(commands, "/dalatest-quoted")
      assert %{description: description} = find(commands, "/dalatest-long")
      assert description == String.duplicate("x", 120)
    end
  end

  describe "project skills (claude)" do
    test "flat name.md and nested name/SKILL.md both define /name", %{cwd: cwd} do
      write_md(cwd, ".claude/skills/dalatest-flat.md", "---\ndescription: Flat skill\n---\n")

      write_md(
        cwd,
        ".claude/skills/dalatest-nested/SKILL.md",
        "---\ndescription: Nested skill\n---\n"
      )

      commands = AgentCommands.list("claude", cwd)

      assert %{description: "Flat skill"} = find(commands, "/dalatest-flat")
      assert %{description: "Nested skill"} = find(commands, "/dalatest-nested")
    end
  end

  describe "Claude plugin cache" do
    test "scans commands and skills below a literal cache path in deterministic order", %{
      cwd: cwd
    } do
      cache = Path.join(cwd, "plugin-cache-[literal]")

      write_md(
        cache,
        "z-plugin/commands/deep/dalatest-zed.md",
        "---\ndescription: Zed plugin command\n---\n"
      )

      write_md(
        cache,
        "a-plugin/commands/dalatest-alpha.md",
        "---\ndescription: Alpha plugin command\n---\n"
      )

      write_md(
        cache,
        "a-plugin/skills/dalatest-plugin-skill/SKILL.md",
        "---\ndescription: Plugin skill\n---\n"
      )

      commands = AgentCommands.scan_plugin_cache(cache)

      assert Enum.map(commands, & &1.name) ==
               ["/dalatest-alpha", "/dalatest-zed", "/dalatest-plugin-skill"]

      assert %{description: "Alpha plugin command"} = find(commands, "/dalatest-alpha")
      assert %{description: "Zed plugin command"} = find(commands, "/dalatest-zed")
      assert %{description: "Plugin skill"} = find(commands, "/dalatest-plugin-skill")
    end
  end

  describe "builtin tables (priv data files)" do
    test "codex list covers the current TUI commands from the official docs", %{cwd: cwd} do
      names = AgentCommands.list("codex", cwd) |> Enum.map(& &1.name)

      for expected <- ~w(/plan /fork /skills /personality /goal /fast /apps /hooks) do
        assert expected in names, "expected #{expected} in codex builtins"
      end
    end

    test "claude list includes bundled-skill commands, not only TUI builtins", %{cwd: cwd} do
      names = AgentCommands.list("claude", cwd) |> Enum.map(& &1.name)

      for expected <- ~w(/code-review /security-review /plan /effort /loop /rewind) do
        assert expected in names, "expected #{expected} in claude builtins"
      end
    end

    test "opencode list includes the newer TUI commands", %{cwd: cwd} do
      names = AgentCommands.list("opencode", cwd) |> Enum.map(& &1.name)
      for expected <- ~w(/thinking /unshare /details /connect), do: assert(expected in names)
    end
  end

  describe "codex custom prompts" do
    test "project .codex/prompts files surface as commands", %{cwd: cwd} do
      write_md(cwd, ".codex/prompts/dalatest-ship.md", """
      ---
      description: Ship it
      ---
      """)

      assert %{description: "Ship it"} =
               find(AgentCommands.list("codex", cwd), "/dalatest-ship")
    end
  end

  describe "user overlays" do
    test "project dala.jsonc agentCommands adds and overrides entries", %{cwd: cwd} do
      File.write!(Path.join(cwd, "dala.jsonc"), """
      {
        // 本地补充：CLI 更新先于 dala 数据表时自己加
        "agentCommands": {
          "codex": [
            { "name": "/dalatest-extra", "description": "Local addition" },
            { "name": "/model", "description": "Overridden description" },
            { "name": "/quit", "hidden": true },
          ],
        },
      }
      """)

      commands = AgentCommands.list("codex", cwd)
      assert %{description: "Local addition"} = find(commands, "/dalatest-extra")
      assert %{description: "Overridden description"} = find(commands, "/model")
      refute find(commands, "/quit")
    end
  end

  describe "i18n" do
    test "zh locales get the Chinese description column, others fall back to English", %{cwd: cwd} do
      zh = AgentCommands.list("claude", cwd, "zhCN")
      assert %{description: "显示帮助和可用命令"} = find(zh, "/help")

      ja = AgentCommands.list("claude", cwd, "ja")
      assert %{description: "Show help and available commands"} = find(ja, "/help")
    end

    test "plain-string overlay descriptions pass through for every locale", %{cwd: cwd} do
      File.write!(Path.join(cwd, "dala.jsonc"), """
      {"agentCommands": {"codex": [{"name": "/dalatest-plain", "description": "原样"}]}}
      """)

      assert %{description: "原样"} =
               find(AgentCommands.list("codex", cwd, "en"), "/dalatest-plain")
    end
  end

  describe "list/2 general behavior" do
    test "claude includes builtins and is deduped + sorted by name", %{cwd: cwd} do
      # a project file shadowing a builtin: the builtin (added first) wins
      write_md(cwd, ".claude/commands/help.md", "---\ndescription: custom help\n---\n")

      commands = AgentCommands.list("claude", cwd)
      names = Enum.map(commands, & &1.name)

      assert %{description: "Show help and available commands"} = find(commands, "/help")
      assert names == Enum.sort(names)
      assert names == Enum.uniq(names)
    end

    test "opencode picks up project .opencode/command files", %{cwd: cwd} do
      write_md(cwd, ".opencode/command/dalatest-oc.md", "---\ndescription: OC command\n---\n")
      write_md(cwd, ".opencode/commands/dalatest-oc2.md", "no frontmatter")

      commands = AgentCommands.list("opencode", cwd)

      assert %{description: "OC command"} = find(commands, "/dalatest-oc")
      assert %{description: ""} = find(commands, "/dalatest-oc2")
      assert find(commands, "/compact")
    end

    test "codex and gemini only ship builtins; unknown agents get nothing", %{cwd: cwd} do
      write_md(cwd, ".claude/commands/dalatest-ignored.md", "x")

      codex = AgentCommands.list("codex", cwd)
      gemini = AgentCommands.list("gemini", cwd)

      assert find(codex, "/diff")
      refute find(codex, "/dalatest-ignored")
      assert find(gemini, "/theme")
      assert AgentCommands.list("mystery-agent", cwd) == []
    end
  end
end
