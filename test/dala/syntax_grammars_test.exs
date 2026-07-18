defmodule Dala.SyntaxGrammarsTest do
  # Touches the shared global grammars dir under the test data_dir.
  use ExUnit.Case, async: false

  alias Dala.SyntaxGrammars

  @grammar %{
    "name" => "MagicPython",
    "scopeName" => "source.python.magic",
    "fileTypes" => ["py", ".pyi"],
    "patterns" => []
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "dala-grammar-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    global = SyntaxGrammars.global_dir()
    File.mkdir_p!(global)

    on_exit(fn ->
      File.rm_rf!(dir)
      File.rm_rf!(global)
    end)

    %{dir: dir, global: global}
  end

  test "lists uploaded global grammars with normalized extensions", %{global: global} do
    File.write!(Path.join(global, "magic.tmLanguage.json"), Jason.encode!(@grammar))

    %{global_dir: ^global, grammars: [grammar]} = SyntaxGrammars.resolve(nil)
    assert grammar.scope_name == "source.python.magic"
    assert grammar.name == "MagicPython"
    assert grammar.extensions == [".py", ".pyi"]
    assert grammar.source == "global"
  end

  test "project dala.jsonc entries come first and may override extensions", %{
    dir: dir,
    global: global
  } do
    File.write!(Path.join(global, "magic.tmLanguage.json"), Jason.encode!(@grammar))

    File.mkdir_p!(Path.join(dir, "syntaxes"))
    File.write!(Path.join(dir, "syntaxes/dm.tmLanguage.json"), Jason.encode!(@grammar))

    File.write!(Path.join(dir, "dala.jsonc"), """
    {
      // private grammars stay on this machine
      "grammars": [
        { "path": "./syntaxes/dm.tmLanguage.json", "extensions": ["dm"] },
      ],
    }
    """)

    sub = Path.join(dir, "lib")
    File.mkdir_p!(sub)

    %{grammars: [project, global_entry]} = SyntaxGrammars.resolve(Path.join(sub, "app.dm"))
    assert project.source == "project"
    assert project.path == Path.join(dir, "syntaxes/dm.tmLanguage.json")
    assert project.extensions == [".dm"]
    assert global_entry.source == "global"
  end

  test "broken grammar files are skipped, not fatal", %{global: global} do
    File.write!(Path.join(global, "broken.json"), "not json at all")
    File.write!(Path.join(global, "no-scope.json"), Jason.encode!(%{"patterns" => []}))

    assert %{grammars: []} = SyntaxGrammars.resolve(nil)
  end
end
