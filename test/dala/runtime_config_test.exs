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

  describe "the rule: a config file present = env ignored entirely" do
    test "file values win over every env form once the file exists" do
      cfg = %{"port" => 5000, "checkOrigin" => true, "host" => "filehost"}

      with_env(%{"PORT" => "6000", "DALA_PORT" => "7000"}, fn ->
        # A stray generic PORT (or even a deliberate DALA_PORT) can never
        # hijack a CONFIGURED install — production determinism.
        assert RuntimeConfig.get_int(cfg, {"DALA_PORT", "PORT"}, "port", 4000) == 5000
      end)

      assert RuntimeConfig.get(cfg, {"DALA_HOST", "PHX_HOST"}, "host", "localhost") == "filehost"

      assert RuntimeConfig.get_bool(
               cfg,
               {"DALA_CHECK_ORIGIN", "PHX_CHECK_ORIGIN"},
               "checkOrigin",
               false
             ) ==
               true

      # Keys absent from the file fall to DEFAULT (not to env): the file is
      # the sole authority once present.
      with_env(%{"DALA_POOL_SIZE" => "99"}, fn ->
        assert RuntimeConfig.get_int(cfg, {"DALA_POOL_SIZE", "POOL_SIZE"}, "poolSize", 10) == 10
      end)
    end

    test "without a file (dev / unmigrated): DALA_-prefixed > bare legacy > default" do
      with_env(%{"PORT" => "6000", "DALA_PORT" => "7000"}, fn ->
        assert RuntimeConfig.get_int(%{}, {"DALA_PORT", "PORT"}, "port", 4000) == 7000
      end)

      with_env(%{"PORT" => "6000"}, fn ->
        assert RuntimeConfig.get_int(%{}, {"DALA_PORT", "PORT"}, "port", 4000) == 6000
      end)

      assert RuntimeConfig.get_int(%{}, {"DALA_PORT", "PORT"}, "port", 4000) == 4000

      assert RuntimeConfig.get_bool(
               %{},
               {"DALA_CHECK_ORIGIN", "PHX_CHECK_ORIGIN"},
               "checkOrigin",
               false
             ) ==
               false
    end

    test "garbage integers are loud, not silent" do
      assert_raise RuntimeError, ~r/positive integer/, fn ->
        RuntimeConfig.get_int(%{"port" => "many"}, {"DALA_PORT", "PORT"}, "port", 4000)
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

      unless Dala.TestPlatform.windows?() do
        assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      end

      # A second named secret joins the same file without clobbering.
      other = RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_X", "tokenSigningSecret")
      refute other == first
      assert RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_X", "secretKeyBase") == first
    end

    @tag :tmp_dir
    test "env secrets apply only WITHOUT a config file (legacy installs)", %{tmp_dir: tmp} do
      with_env(%{"DALA_TEST_SECRET_Y" => "from-env", "DALA_DATA_DIR" => tmp}, fn ->
        assert RuntimeConfig.secret(%{}, "DALA_TEST_SECRET_Y", "secretKeyBase") == "from-env"
      end)

      refute File.exists?(Path.join(tmp, "secrets.json"))

      # With a file present the env secret is ignored — generated instead.
      cfg = %{"dataDir" => tmp}

      with_env(%{"DALA_TEST_SECRET_Y" => "from-env"}, fn ->
        refute RuntimeConfig.secret(cfg, "DALA_TEST_SECRET_Y", "secretKeyBase") == "from-env"
      end)
    end
  end

  test "data_dir: env > file > XDG default, tilde/relative expanded" do
    assert RuntimeConfig.data_dir(%{"dataDir" => "~/dala-data"}) ==
             Path.expand("~/dala-data")

    with_env(%{"DALA_DATA_DIR" => "/tmp/env-wins"}, fn ->
      # File present → env ignored, even for the data dir.
      assert Dala.TestPlatform.same_path?(
               RuntimeConfig.data_dir(%{"dataDir" => "/tmp/file"}),
               Path.expand("/tmp/file")
             )

      assert Dala.TestPlatform.same_path?(
               RuntimeConfig.data_dir(%{}),
               Path.expand("/tmp/env-wins")
             )
    end)

    assert RuntimeConfig.data_dir(%{}) =~ ~r{/dala$}
  end

  describe "file_limits" do
    test "env (MB) > limits object > default, converted to bytes" do
      cfg = %{"limits" => %{"drawerUploadMaxMb" => 100, "textSaveMaxMb" => 5}}

      limits = RuntimeConfig.file_limits(cfg)
      assert limits.drawer_upload_bytes == 100 * 1024 * 1024
      assert limits.text_write_bytes == 5 * 1024 * 1024
      assert limits.browser_attachment_bytes == 512 * 1024 * 1024

      with_env(%{"DALA_DRAWER_UPLOAD_MAX_MB" => "7"}, fn ->
        # File present → env ignored; without a file → env applies.
        assert RuntimeConfig.file_limits(cfg).drawer_upload_bytes == 100 * 1024 * 1024
        assert RuntimeConfig.file_limits(%{}).drawer_upload_bytes == 7 * 1024 * 1024
      end)
    end

    test "garbage sizes and preview-default > preview-max are loud" do
      assert_raise RuntimeError, ~r/positive integer in MB/, fn ->
        RuntimeConfig.file_limits(%{"limits" => %{"textSaveMaxMb" => "big"}})
      end

      assert_raise RuntimeError, ~r/cannot exceed/, fn ->
        RuntimeConfig.file_limits(%{
          "limits" => %{"textPreviewDefaultMb" => 32, "textPreviewMaxMb" => 16}
        })
      end
    end
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
