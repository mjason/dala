defmodule Dala.RuntimeConfig do
  @moduledoc """
  Server configuration from a FILE, not from environment variables.

  Rationale (user decision): dala's own configuration living in the process
  environment was the root of a whole bug family — every variable in the
  service's environment leaks toward spawned shells and toward anything the
  server starts, and the cure (scrubbing) treats the symptom. With
  configuration in `config.jsonc` and secrets auto-managed in the data dir,
  the server process needs essentially NO environment of its own: nothing
  to leak, nothing to scrub, no collision with whatever the user runs.

  The rule (user decision): environment variables are a DEVELOPMENT tool
  and a legacy-compat path — production uses the file, full stop.

  - Config file present (`$DALA_CONFIG` or `$XDG_CONFIG_HOME/dala/
    config.jsonc`, JSONC): the file is the sole authority; every env
    override is ignored. Deterministic — nothing ambient (a stray generic
    `PORT` in whatever shell started the server!) can affect a configured
    install.
  - No config file (development, or an unmigrated dala.env install): env
    applies — `DALA_`-prefixed names first (collision-free, the documented
    dev knobs), then the bare legacy names (`PORT`, `PHX_HOST`, …), then
    defaults.

  Secrets (`secret_key_base`, `token_signing_secret`) never appear in the
  config file: they are generated on first boot and persisted 0600 at
  `<data_dir>/secrets.json`. A legacy env value still wins for old installs.
  """

  @doc "Parsed config file as a map (empty when absent/broken — defaults rule)."
  def load do
    path =
      System.get_env("DALA_CONFIG") ||
        Path.join(config_home(), "dala/config.jsonc")

    with {:ok, body} <- File.read(path),
         {:ok, parsed} when is_map(parsed) <- Jason.decode(Dala.Jsonc.strip(body)) do
      parsed
    else
      {:error, :enoent} ->
        %{}

      other ->
        IO.warn("dala: could not parse #{path} (#{inspect(other)}) — using defaults")
        %{}
    end
  end

  @doc """
  String value. Precedence: `DALA_`-prefixed env (deliberate, collision-free
  — for development) > config file > bare legacy env (old dala.env installs;
  BELOW the file so an ambient generic name like `PORT` in whatever shell
  started the server can never hijack a configured install) > default.

  `env_var` is either one name or `{primary, legacy}`.
  """
  def get(cfg, env_var, file_key, default \\ nil) do
    value =
      if env_enabled?(cfg) do
        {primary, legacy} = env_pair(env_var)
        System.get_env(primary) || (legacy && System.get_env(legacy))
      else
        file_value(cfg, file_key)
      end

    case value || default do
      nil -> nil
      found -> to_string(found)
    end
  end

  # Env applies ONLY when there is no config file: the file, once present,
  # is the sole authority (production determinism).
  defp env_enabled?(cfg), do: cfg == %{}

  defp env_pair({primary, legacy}), do: {primary, legacy}
  defp env_pair(name) when is_binary(name), do: {name, nil}

  defp file_value(cfg, file_key) do
    case Map.get(cfg, file_key) do
      nil -> nil
      value -> to_string(value)
    end
  end

  @doc "Boolean value (env accepts true/1); same precedence as `get/4`."
  def get_bool(cfg, env_var, file_key, default) do
    if env_enabled?(cfg) do
      {primary, legacy} = env_pair(env_var)

      case System.get_env(primary) || (legacy && System.get_env(legacy)) do
        value when value in [nil, false] -> default
        value -> value in ~w(true 1)
      end
    else
      case Map.fetch(cfg, file_key) do
        {:ok, value} -> value in [true, "true", "1", 1]
        :error -> default
      end
    end
  end

  @doc "Positive integer value; raises on garbage (config typos must be loud)."
  def get_int(cfg, env_var, file_key, default) do
    raw = get(cfg, env_var, file_key, default)

    case raw && Integer.parse(to_string(raw)) do
      {value, ""} when value > 0 ->
        value

      nil ->
        nil

      _ ->
        raise "invalid #{file_key} (expected a positive integer, got #{inspect(raw)})"
    end
  end

  @doc "The data directory (tilde expanded), from env/file/XDG default."
  def data_dir(cfg) do
    (get(cfg, "DALA_DATA_DIR", "dataDir") ||
       Path.join(System.get_env("XDG_DATA_HOME") || Path.join(home(), ".local/share"), "dala"))
    |> Path.expand()
  end

  @doc """
  A named secret: legacy env > persisted secrets file > freshly generated
  and persisted (0600). The file lives in the data dir so it survives
  upgrades and never needs to be written by a human.
  """
  def secret(cfg, env_var, file_key) do
    {primary, legacy} = env_pair(env_var)

    env_value =
      if env_enabled?(cfg),
        do: System.get_env(primary) || (legacy && System.get_env(legacy)),
        else: nil

    case env_value do
      value when value in [nil, false] ->
        path = Path.join(data_dir(cfg), "secrets.json")
        secrets = read_secrets(path)

        case Map.get(secrets, file_key) do
          value when is_binary(value) and value != "" ->
            value

          _ ->
            value = generate_secret()
            persist_secrets(path, Map.put(secrets, file_key, value))
            value
        end

      value ->
        value
    end
  end

  @doc """
  Upload/preview size limits in BYTES: legacy env (MB) > `limits` object in
  the config file (MB) > default. Garbage raises — a size typo silently
  becoming a default is how quota surprises happen.
  """
  def file_limits(cfg) do
    limits = cfg["limits"] || %{}

    mb = fn env_var, file_key, default ->
      raw =
        if env_enabled?(cfg) do
          System.get_env(env_var) || default
        else
          Map.get(limits, file_key, default)
        end

      case Integer.parse(to_string(raw)) do
        {value, ""} when value > 0 -> value * 1024 * 1024
        _ -> raise "invalid #{file_key}/#{env_var} (expected a positive integer in MB)"
      end
    end

    preview_default = mb.("DALA_TEXT_PREVIEW_DEFAULT_MB", "textPreviewDefaultMb", 1)
    preview_max = mb.("DALA_TEXT_PREVIEW_MAX_MB", "textPreviewMaxMb", 16)

    if preview_default > preview_max do
      raise "textPreviewDefaultMb cannot exceed textPreviewMaxMb"
    end

    %{
      drawer_upload_bytes: mb.("DALA_DRAWER_UPLOAD_MAX_MB", "drawerUploadMaxMb", 2048),
      browser_attachment_bytes:
        mb.("DALA_BROWSER_ATTACHMENT_MAX_MB", "browserAttachmentMaxMb", 512),
      mcp_attachment_bytes: mb.("DALA_MCP_ATTACHMENT_MAX_MB", "mcpAttachmentMaxMb", 64),
      managed_attachment_bytes:
        mb.("DALA_ATTACHMENT_STORAGE_MAX_MB", "attachmentStorageMaxMb", 5120),
      text_write_bytes: mb.("DALA_TEXT_SAVE_MAX_MB", "textSaveMaxMb", 50),
      preview_default_bytes: preview_default,
      preview_max_bytes: preview_max
    }
  end

  defp read_secrets(path) do
    with {:ok, body} <- File.read(path),
         {:ok, parsed} when is_map(parsed) <- Jason.decode(body) do
      parsed
    else
      _ -> %{}
    end
  end

  defp persist_secrets(path, secrets) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(secrets, pretty: true) <> "\n")
    File.chmod!(path, 0o600)
  end

  defp generate_secret, do: 48 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

  defp config_home,
    do: System.get_env("XDG_CONFIG_HOME") || Path.join(home(), ".config")

  defp home, do: System.user_home() || "/"
end
