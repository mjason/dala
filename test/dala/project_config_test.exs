defmodule Dala.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias Dala.ProjectConfig

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dala-project-config-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "no config anywhere: exists false, target path inside dir", %{dir: dir} do
    assert %{path: path, exists: false, prompt: ""} = ProjectConfig.speech_prompt(dir)
    assert path == Path.join(dir, "dala.jsonc")
  end

  test "set creates a fresh dala.jsonc in the directory and round-trips", %{dir: dir} do
    assert {:ok, path} = ProjectConfig.put_speech_prompt(dir, "dala, zellij, Phoenix")
    assert path == Path.join(dir, "dala.jsonc")

    assert %{path: ^path, exists: true, prompt: "dala, zellij, Phoenix"} =
             ProjectConfig.speech_prompt(dir)
  end

  test "updating an existing config preserves comments and other sections", %{dir: dir} do
    path = Path.join(dir, "dala.jsonc")

    File.write!(path, """
    {
      // my precious hand-written comment
      "lsp": {
        "python": [{ "command": ["basedpyright-langserver", "--stdio"] }]
      },
      "speech": {
        // old words
        "prompt": "old stuff"
      }
    }
    """)

    assert {:ok, ^path} = ProjectConfig.put_speech_prompt(dir, "new, words")

    body = File.read!(path)
    assert body =~ "my precious hand-written comment"
    assert body =~ "// old words"
    assert body =~ "basedpyright-langserver"
    assert %{prompt: "new, words"} = ProjectConfig.speech_prompt(dir)
  end

  test "inserts a prompt into an existing speech block that lacks one", %{dir: dir} do
    path = Path.join(dir, "dala.jsonc")

    File.write!(path, """
    {
      "speech": {
        "somethingElse": true
      }
    }
    """)

    assert {:ok, ^path} = ProjectConfig.put_speech_prompt(dir, "words")
    assert %{prompt: "words"} = ProjectConfig.speech_prompt(dir)
    assert File.read!(path) =~ "somethingElse"
  end

  test "inserts a speech block into a config without one", %{dir: dir} do
    path = Path.join(dir, "dala.jsonc")

    File.write!(path, """
    {
      // keep me
      "lsp": { "python": [] }
    }
    """)

    assert {:ok, ^path} = ProjectConfig.put_speech_prompt(dir, "words")
    assert %{prompt: "words"} = ProjectConfig.speech_prompt(dir)
    body = File.read!(path)
    assert body =~ "// keep me"
    assert body =~ "\"lsp\""
  end

  test "the nearest ancestor config wins for reads AND writes", %{dir: dir} do
    child = Path.join(dir, "apps/web")
    File.mkdir_p!(child)
    parent_config = Path.join(dir, "dala.jsonc")
    File.write!(parent_config, ~s({ "speech": { "prompt": "parent words" } }\n))

    assert %{path: ^parent_config, prompt: "parent words"} =
             ProjectConfig.speech_prompt(child)

    assert {:ok, ^parent_config} = ProjectConfig.put_speech_prompt(child, "edited")
    refute File.exists?(Path.join(child, "dala.jsonc"))
    assert %{prompt: "edited"} = ProjectConfig.speech_prompt(child)
  end

  test "a prompt with quotes and CJK survives the JSON encoding", %{dir: dir} do
    words = ~s(数据库, "quoted", Phoenix LiveView)
    assert {:ok, _} = ProjectConfig.put_speech_prompt(dir, words)
    assert %{prompt: ^words} = ProjectConfig.speech_prompt(dir)
  end

  test "clearing the prompt writes an empty string, not a broken file", %{dir: dir} do
    assert {:ok, path} = ProjectConfig.put_speech_prompt(dir, "words")
    assert {:ok, ^path} = ProjectConfig.put_speech_prompt(dir, "")
    assert %{prompt: ""} = ProjectConfig.speech_prompt(dir)
    assert {:ok, %{}} = Jason.decode(Dala.Lsp.Discovery.strip_jsonc(File.read!(path)))
  end
end
