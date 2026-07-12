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
    assert %{path: path, exists: false, hotwords: ""} = ProjectConfig.speech_hotwords(dir)
    assert path == Path.join(dir, "dala.jsonc")
  end

  test "set creates a fresh dala.jsonc in the directory and round-trips", %{dir: dir} do
    assert {:ok, path} = ProjectConfig.put_speech_hotwords(dir, "dala, zellij, Phoenix")
    assert path == Path.join(dir, "dala.jsonc")

    assert %{path: ^path, exists: true, hotwords: "dala, zellij, Phoenix"} =
             ProjectConfig.speech_hotwords(dir)
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
        "hotwords": "old stuff"
      }
    }
    """)

    assert {:ok, ^path} = ProjectConfig.put_speech_hotwords(dir, "new, words")

    body = File.read!(path)
    assert body =~ "my precious hand-written comment"
    assert body =~ "// old words"
    assert body =~ "basedpyright-langserver"
    assert %{hotwords: "new, words"} = ProjectConfig.speech_hotwords(dir)
  end

  test "inserts hotwords into an existing speech block that lacks them", %{dir: dir} do
    path = Path.join(dir, "dala.jsonc")

    File.write!(path, """
    {
      "speech": {
        "somethingElse": true
      }
    }
    """)

    assert {:ok, ^path} = ProjectConfig.put_speech_hotwords(dir, "words")
    assert %{hotwords: "words"} = ProjectConfig.speech_hotwords(dir)
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

    assert {:ok, ^path} = ProjectConfig.put_speech_hotwords(dir, "words")
    assert %{hotwords: "words"} = ProjectConfig.speech_hotwords(dir)
    body = File.read!(path)
    assert body =~ "// keep me"
    assert body =~ "\"lsp\""
  end

  test "the nearest ancestor config wins for reads AND writes", %{dir: dir} do
    child = Path.join(dir, "apps/web")
    File.mkdir_p!(child)
    parent_config = Path.join(dir, "dala.jsonc")
    File.write!(parent_config, ~s({ "speech": { "hotwords": "parent words" } }\n))

    assert %{path: ^parent_config, hotwords: "parent words"} =
             ProjectConfig.speech_hotwords(child)

    assert {:ok, ^parent_config} = ProjectConfig.put_speech_hotwords(child, "edited")
    refute File.exists?(Path.join(child, "dala.jsonc"))
    assert %{hotwords: "edited"} = ProjectConfig.speech_hotwords(child)
  end

  test "hotwords with quotes and CJK survive the JSON encoding", %{dir: dir} do
    words = ~s(数据库, "quoted", Phoenix LiveView)
    assert {:ok, _} = ProjectConfig.put_speech_hotwords(dir, words)
    assert %{hotwords: ^words} = ProjectConfig.speech_hotwords(dir)
  end

  test "clearing hotwords writes an empty string, not a broken file", %{dir: dir} do
    assert {:ok, path} = ProjectConfig.put_speech_hotwords(dir, "words")
    assert {:ok, ^path} = ProjectConfig.put_speech_hotwords(dir, "")
    assert %{hotwords: ""} = ProjectConfig.speech_hotwords(dir)
    assert {:ok, %{}} = Jason.decode(Dala.Lsp.Discovery.strip_jsonc(File.read!(path)))
  end
end
