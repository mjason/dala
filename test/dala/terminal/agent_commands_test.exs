defmodule Dala.Terminal.AgentCommandsTest do
  # Reads real user-home command dirs alongside the temp project dir, so all
  # assertions are membership-based with unique names (never full-list equality).
  use ExUnit.Case, async: true

  alias Dala.Terminal.AgentCommands

  setup do
    cwd = Path.join(System.tmp_dir!(), "agent-cmds-#{System.unique_integer([:positive])}")
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
