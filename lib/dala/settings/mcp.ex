defmodule Dala.Settings.Mcp do
  @moduledoc """
  The MCP endpoint's runtime configuration — a single, INSTANCE-WIDE row.

  Unlike `Dala.Settings.Speech`/`Dala.Settings.Theme` (which are per-owner),
  the `/mcp` gate is one shared door for the whole dala instance, so this is a
  true global singleton: exactly one row, addressed by a fixed sentinel id
  (`@singleton_id`). Whoever can toggle it toggles it for everybody.

  It replaces the old `DALA_MCP_ENABLED`/`DALA_MCP_TOKEN` environment variables:
  MCP is now flipped on/off at RUNTIME from the web Settings panel (no restart),
  and the bearer `token` is SERVER-GENERATED (high-entropy, url-safe) and shown
  in that panel so it can be copied into an MCP client. The first read
  auto-provisions the row with a freshly generated token; `enabled` defaults to
  `false`, so a brand-new install is closed until someone turns it on.

  The token is NOT `sensitive?`: the web UI is the control surface and must be
  able to display it. That is consistent with the UI already being auth-gated
  and localhost-bound — anyone who can open it already owns the box.

  SECURITY: this resource is deliberately EXCLUDED from the MCP tool registry
  (see `Dala.Mcp.Registry`). An AI talking to `/mcp` must never get tools to
  toggle MCP, read, or rotate its own bearer token. Its three rpc actions
  (`:current`/`:set_enabled`/`:regenerate_token`) are for the auth-gated web UI
  via `/rpc/run` only.
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Settings,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  require Ash.Query

  # The one and only row. Fixed so provisioning is idempotent: an upsert on the
  # primary key means two concurrent first-reads converge on this row instead
  # of colliding.
  @singleton_id "00000000-0000-0000-0000-0000000000c1"

  # 24 random bytes -> 32 url-safe base64 chars (no padding). High entropy,
  # safe to paste into an `Authorization: Bearer` header verbatim.
  @token_bytes 24

  sqlite do
    table "mcp_config"
    repo Dala.Repo
  end

  typescript do
    type_name "McpConfig"
  end

  actions do
    # DANGER — `:provision` and `:write` are internal plumbing for the helpers
    # below and MUST NEVER be added to `typescript_rpc` in `Dala.Settings`.
    # Exposing them would let a client plant an arbitrary token or flip
    # `enabled` while bypassing the intended `:set_enabled`/`:regenerate_token`
    # surface. Only the three generic actions are safe to expose.
    defaults [:read]

    # Idempotent create of the singleton. `upsert?` on the primary key makes a
    # concurrent double-provision safe: the loser hits the conflict and touches
    # `updated_at` instead of raising, and the pre-existing token is preserved
    # (it is NOT in `upsert_fields`, so a race never clobbers a live token).
    create :provision do
      accept [:id, :enabled, :token]
      upsert? true
      upsert_fields [:updated_at]
    end

    update :write do
      accept [:enabled, :token]
    end

    action :current, :map do
      description "The instance MCP config: whether /mcp is enabled and the bearer token. Provisions a token on first read."

      constraints fields: [
                    enabled: [type: :boolean],
                    token: [type: :string]
                  ]

      run fn _input, _context -> {:ok, current()} end
    end

    action :set_enabled, :map do
      description "Enable or disable the /mcp endpoint instance-wide. Returns the current {enabled, token}."

      argument :enabled, :boolean, allow_nil?: false

      constraints fields: [
                    enabled: [type: :boolean],
                    token: [type: :string]
                  ]

      run fn input, _context -> {:ok, set_enabled(input.arguments.enabled)} end
    end

    action :regenerate_token, :map do
      description "Generate a NEW bearer token, replacing the old one (which stops working immediately). Returns the new token."

      constraints fields: [token: [type: :string]]

      run fn _input, _context -> {:ok, regenerate_token()} end
    end
  end

  attributes do
    # Writable so the fixed singleton id can be planted; the public actions
    # never accept `:id`, they always resolve the singleton themselves.
    uuid_primary_key :id, writable?: true, public?: true

    attribute :enabled, :boolean do
      description "Whether POST /mcp is reachable. Off on a fresh install."
      public? true
      allow_nil? false
      default false
    end

    attribute :token, :string do
      description "Server-generated bearer token. Shown in the web UI; NOT sensitive so it can be displayed/copied."
      public? true
      allow_nil? false
      # allow_empty? so the defensive fail-closed path (enabled + blank token
      # -> 503) is reachable/testable; the normal path always stores a real,
      # generated token.
      constraints allow_empty?: true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  @doc """
  Provision-and-read `{enabled, token}` for the authed `:current` path (the
  Settings panel): ensures the singleton exists, minting a token on first call.
  """
  def config do
    row = ensure()
    {row.enabled, row.token}
  end

  @doc """
  Read-only `{enabled, token}` for the unauthenticated `/mcp` gate — it must
  NEVER write. A missing singleton reads as `{false, nil}` (disabled → 404);
  the row is provisioned lazily by `config/0` when the operator opens the panel.
  This keeps an unauth burst against a disabled endpoint from forcing DB writes.
  """
  def config_or_default do
    case read() do
      nil -> {false, nil}
      row -> {row.enabled, row.token}
    end
  end

  @doc "The `{enabled, token}` config as a map, for the `:current` rpc action."
  def current do
    {enabled, token} = config()
    %{enabled: enabled, token: token}
  end

  @doc "Set `enabled` instance-wide; returns the resulting `%{enabled, token}`."
  def set_enabled(enabled) when is_boolean(enabled) do
    saved =
      ensure()
      |> Ash.Changeset.for_update(:write, %{enabled: enabled}, authorize?: false)
      |> Ash.update!(authorize?: false)

    %{enabled: saved.enabled, token: saved.token}
  end

  @doc """
  Replace the token with a freshly generated one and return `%{token: new}`.
  The previous token stops authorizing as soon as this row is written.
  """
  def regenerate_token do
    saved =
      ensure()
      |> Ash.Changeset.for_update(:write, %{token: generate_token()}, authorize?: false)
      |> Ash.update!(authorize?: false)

    %{token: saved.token}
  end

  # The singleton row, provisioning it (with a generated token) if absent.
  defp ensure, do: read() || provision()

  defp read do
    __MODULE__
    |> Ash.Query.filter(id == ^@singleton_id)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # Upsert the fixed row, then re-read: whether we inserted it or lost the race
  # to a concurrent caller, the canonical row is now in place.
  defp provision do
    Ash.create!(
      __MODULE__,
      %{id: @singleton_id, enabled: false, token: generate_token()},
      action: :provision,
      authorize?: false
    )

    read() || raise "MCP singleton could not be provisioned"
  end

  defp generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
