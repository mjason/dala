defmodule Dala.Lsp.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Dala.Lsp.Discovery

  setup do
    root = Path.join(System.tmp_dir!(), "lsp-discovery-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(root)
    {:ok, root: root}
  end

  defp fake_bin(root, rel) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
    path
  end

  test "unknown extensions get no servers", %{root: root} do
    assert Discovery.servers(root, "notes.txt") == []
  end

  test "venv basedpyright wins for python", %{root: root} do
    bin = fake_bin(root, ".venv/bin/basedpyright-langserver")
    fake_bin(root, ".venv/bin/pyright-langserver")

    assert [%{name: "basedpyright", command: [^bin, "--stdio"]}] =
             Discovery.servers(root, "main.py")
  end

  test "dmagic.py workspaces get dm lsp appended", %{root: root} do
    pyright = fake_bin(root, ".venv/bin/pyright-langserver")
    dm = fake_bin(root, ".venv/bin/dm")
    File.write!(Path.join(root, "dmagic.py"), "workspace = ...\n")

    assert [
             %{id: 0, name: "pyright", command: [^pyright, "--stdio"]},
             %{id: 1, name: "dm lsp", command: [^dm, "lsp"]}
           ] = Discovery.servers(root, "strategies/alpha.py")
  end

  test "dm without dmagic.py marker is not attached", %{root: root} do
    fake_bin(root, ".venv/bin/pyright-langserver")
    fake_bin(root, ".venv/bin/dm")

    assert [%{name: "pyright"}] = Discovery.servers(root, "main.py")
  end

  test ".dala/lsp.json overrides discovery, relative commands resolve", %{root: root} do
    fake_bin(root, ".venv/bin/basedpyright-langserver")
    custom = fake_bin(root, "tools/my-lsp")
    File.mkdir_p!(Path.join(root, ".dala"))

    File.write!(
      Path.join(root, ".dala/lsp.json"),
      ~s({"python": [{"command": ["tools/my-lsp", "--custom"]}]})
    )

    assert [%{name: "my-lsp", command: [^custom, "--custom"]}] =
             Discovery.servers(root, "main.py")
  end

  test "malformed .dala/lsp.json falls back to discovery", %{root: root} do
    bin = fake_bin(root, ".venv/bin/pyright-langserver")
    File.mkdir_p!(Path.join(root, ".dala"))
    File.write!(Path.join(root, ".dala/lsp.json"), "not json {")

    assert [%{command: [^bin, "--stdio"]}] = Discovery.servers(root, "main.py")
  end

  test "probe records every candidate checked, found or not", %{root: root} do
    bin = fake_bin(root, ".venv/bin/pyright-langserver")

    probe = Discovery.probe(root, "main.py")
    assert probe.language == "python"
    assert [%{name: "pyright"}] = probe.servers
    assert Enum.any?(probe.checked, &(&1.path == bin and &1.found))
    assert Enum.any?(probe.checked, &(not &1.found))
  end

  test "probe with nothing found still explains itself", %{root: root} do
    File.mkdir_p!(Path.join(root, ".dala"))

    File.write!(
      Path.join(root, ".dala/lsp.json"),
      ~s({"rust": [{"command": ["tools/missing-lsp"]}]})
    )

    probe = Discovery.probe(root, "main.rs")
    assert probe.language == "rust"
    assert probe.servers == []
    assert [%{found: false, path: path}] = probe.checked
    assert path =~ "missing-lsp"
  end

  test "root dala.jsonc with comments, $HOME and ${root} expansion", %{root: root} do
    fake_bin(root, "tools/custom-lsp")
    home_rel = Path.relative_to(root, System.user_home!())

    File.write!(Path.join(root, "dala.jsonc"), """
    {
      // project-wide dala config — LSP overrides live under "lsp"
      "lsp": {
        /* python uses a custom server */
        "python": [
          { "command": ["${root}/tools/custom-lsp", "--stdio"] },
          { "command": ["$HOME/#{home_rel}/tools/custom-lsp", "--alt"] },
        ],
      },
    }
    """)

    probe = Discovery.probe(root, "main.py")
    expected = Path.join(root, "tools/custom-lsp")

    assert [
             %{name: "custom-lsp", command: [^expected, "--stdio"]},
             %{name: "custom-lsp", command: [^expected, "--alt"]}
           ] = probe.servers

    assert Enum.all?(probe.checked, & &1.found)
  end

  test "tilde expansion in .dala/lsp.json", %{root: root} do
    home_rel = Path.relative_to(root, System.user_home!())
    fake_bin(root, "tools/tilde-lsp")
    File.mkdir_p!(Path.join(root, ".dala"))

    File.write!(
      Path.join(root, ".dala/lsp.json"),
      ~s({"python": [{"command": ["~/#{home_rel}/tools/tilde-lsp"]}]})
    )

    assert [%{name: "tilde-lsp"}] = Discovery.servers(root, "main.py")
  end

  test "language ids cover the wired languages" do
    assert Discovery.language_of("a.py") == "python"
    assert Discovery.language_of("a.rs") == "rust"
    assert Discovery.language_of("a.ex") == "elixir"
    assert Discovery.language_of("a.heex") == "elixir"
    assert Discovery.language_of("a.lua") == "lua"
    assert Discovery.language_of("a.md") == nil
  end
end
