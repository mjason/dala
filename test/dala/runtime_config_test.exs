defmodule Dala.RuntimeConfigTest do
  # System.put_env is process-global — keep out of async.
  use ExUnit.Case, async: false

  alias Dala.RuntimeConfig

  @tag :tmp_dir
  test "loads JSONC (comments + trailing commas) from DALA_CONFIG", %{tmp_dir: tmp} do
    path = Path.join(tmp, "config.jsonc")

    File.write!(path, """
    {
      // 注释也合法
      "port": 4567,
      "auth": { "enabled": true, },
    }
    """)

    with_env(%{"DALA_CONFIG" => path}, fn ->
      cfg = RuntimeConfig.load()
      assert cfg["port"] == 4567
      assert cfg["auth"]["enabled"] == true
    end)
  end

  @tag :tmp_dir
  test "missing or broken files fall back to empty (defaults rule)", %{tmp_dir: tmp} do
    with_env(%{"DALA_CONFIG" => Path.join(tmp, "nope.jsonc")}, fn ->
      assert RuntimeConfig.load() == %{}
    end)

    broken = Path.join(tmp, "broken.jsonc")
    File.write!(broken, "{ not json")

    with_env(%{"DALA_CONFIG" => broken}, fn ->
      assert RuntimeConfig.load() == %{}
    end)
  end

  describe "precedence: legacy env > file > default" do
    test "get/get_int/get_bool" do
      cfg = %{"port" => 5000, "checkOrigin" => true, "host" => "filehost"}

      with_env(%{"PORT" => "6000"}, fn ->
        assert RuntimeConfig.get_int(cfg, "PORT", "port", 4000) == 6000
      end)

      assert RuntimeConfig.get_int(cfg, "PORT", "port", 4000) == 5000
      assert RuntimeConfig.get_int(%{}, "PORT", "port", 4000) == 4000
      assert RuntimeConfig.get(cfg, "PHX_HOST", "host", "localhost") == "filehost"
      assert RuntimeConfig.get_bool(cfg, "PHX_CHECK_ORIGIN", "checkOrigin", false) == true
      assert RuntimeConfig.get_bool(%{}, "PHX_CHECK_ORIGIN", "checkOrigin", false) == false

      with_env(%{"PHX_CHECK_ORIGIN" => "false"}, fn ->
        assert RuntimeConfig.get_bool(cfg, "PHX_CHECK_ORIGIN", "checkOrigin", false) == false
      end)
    end

    test "garbage integers are loud, not silent" do
      assert_raise RuntimeError, ~r/positive integer/, fn ->
        RuntimeConfig.get_int(%{"port" => "many"}, "PORT", "port", 4000)
      end
    end
  end

  describe "secrets" do
    @tag :tmp_dir
    test "generated once, persisted 0600, stable across loads", %{tmp_dir: tmp} do
      cfg = %{"dataDir" => tmp}

      first = RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_X", "secretKeyBase")
      second = RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_X", "secretKeyBase")
      assert first == second
      assert byte_size(first) > 40

      path = Path.join(tmp, "secrets.json")
      assert File.exists?(path)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

      # A second named secret joins the same file without clobbering.
      other = RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_X", "tokenSigningSecret")
      refute other == first
      assert RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_X", "secretKeyBase") == first
    end

    @tag :tmp_dir
    test "legacy env override wins and writes nothing", %{tmp_dir: tmp} do
      cfg = %{"dataDir" => tmp}

      with_env(%{"DALA_TEST_SECRET_Y" => "from-env"}, fn ->
        assert RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_Y", "secretKeyBase") == "from-env"
      end)

      refute File.exists?(Path.join(tmp, "secrets.json"))
    end
  end

  test "data_dir: env > file > XDG default, tilde/relative expanded" do
    assert RuntimeConfig.data_dir(%{"dataDir" => "~/dala-data"}) ==
             Path.expand("~/dala-data")

    with_env(%{"DALA_DATA_DIR" => "/tmp/env-wins"}, fn ->
      assert RuntimeConfig.data_dir(%{"dataDir" => "/tmp/file"}) == "/tmp/env-wins"
    end)

    assert RuntimeConfig.data_dir(%{}) =~ ~r{/dala$}
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
