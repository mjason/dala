defmodule Dala.Settings.Speech do
  @moduledoc """
  The speech (voice input) configuration: which OpenAI-compatible
  transcription endpoint to forward recordings to, which model to ask for
  and the API key to present.

  Server-side on purpose. It used to live in browser localStorage, which
  meant reconfiguring it on every device — and it let any client make the
  server POST audio to an arbitrary URL (SSRF). Now the client never sends
  an endpoint; `Dala.Terminal.Speech.transcribe` reads it from here.

  One row per user, plus one "global" row (`user_id == nil`) used whenever
  there is no actor — the default install runs with authentication off, and
  then everybody shares that row. Singleton-ness is enforced by the primary
  key: a row's id IS its owner's user id (SQLite can't do `NULLS NOT
  DISTINCT`, so the ownerless row takes a sentinel uuid instead).

  The API key is `sensitive?` and never leaves the server: reads expose
  `api_key_set` (a boolean) instead.
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Settings,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  require Ash.Query

  sqlite do
    table "speech_settings"
    repo Dala.Repo

    references do
      # A user's speech row is meaningless without the user; when the user is
      # deleted the row goes with them (no orphan, no dangling FK). This is
      # the intended behaviour — losing the endpoint/key alongside its owner
      # is correct, not data loss.
      reference :user, on_delete: :delete
    end
  end

  typescript do
    type_name "SpeechSettings"
  end

  actions do
    # DANGER — these three (`:read`, `:upsert`, `:put`) MUST NEVER be added to
    # the `typescript_rpc` block in `Dala.Settings`. They are internal plumbing
    # for the server-side helpers below; only `:current` and `:save` are safe
    # to expose. Exposing `:read` would leak the shared global row (and its
    # `api_key_set`) to every client regardless of actor; exposing `:upsert`
    # or `:put` would let a client write ANY row id — including another user's
    # or the global one — collapsing the per-owner isolation entirely.
    defaults [:read]

    create :upsert do
      accept [:id, :user_id, :endpoint, :model]
      upsert? true

      # `api_key` is a private attribute (so it can't even be named in a
      # generated client type) — it rides in as an argument instead.
      argument :api_key, :string, sensitive?: true
      change set_attribute(:api_key, arg(:api_key))
    end

    update :put do
      accept [:endpoint, :model]
      argument :api_key, :string, sensitive?: true
      change set_attribute(:api_key, arg(:api_key))
    end

    action :current, :map do
      description "The caller's speech settings; empty defaults when unset. Never returns the API key."

      constraints fields: [
                    endpoint: [type: :string],
                    model: [type: :string],
                    api_key_set: [type: :boolean]
                  ]

      run fn _input, context -> {:ok, summary(context.actor)} end
    end

    action :save, :map do
      description """
      Store the caller's speech settings. An omitted or empty `api_key`
      leaves the stored key untouched; `clear_api_key: true` wipes it.
      """

      # nil = leave as is; "" = clear.
      argument :endpoint, :string, constraints: [allow_empty?: true]
      argument :model, :string, constraints: [allow_empty?: true]

      # "" is cast to nil by Ash.Type.String (allow_empty? defaults to
      # false) — which is exactly the "leave the stored key alone" case.
      argument :api_key, :string, sensitive?: true
      argument :clear_api_key, :boolean, default: false

      constraints fields: [
                    endpoint: [type: :string],
                    model: [type: :string],
                    api_key_set: [type: :boolean]
                  ]

      run fn input, context ->
        save(context.actor, input.arguments)
      end
    end
  end

  attributes do
    # Writable: the id IS the owner (a user's uuid, or the global sentinel),
    # which is what makes the row a per-owner singleton at the DB level.
    uuid_primary_key :id, writable?: true, public?: true

    attribute :endpoint, :string do
      public? true
      allow_nil? false
      default ""
      constraints allow_empty?: true
    end

    attribute :model, :string do
      public? true
      allow_nil? false
      default ""
      constraints allow_empty?: true
    end

    attribute :api_key, :string do
      # Stored PLAINTEXT in SQLite. Acceptable for a self-hosted, single-tenant
      # install: whoever can read the .db file already owns the box (and the
      # shells it spawns) — encrypting at rest here would only guard against an
      # attacker who already has everything. It is never exposed over RPC
      # (private + sensitive) — see the `current`/`save` actions.
      description "Private + sensitive: never exposed over RPC — see the `current`/`save` actions."
      public? false
      sensitive? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Dala.Accounts.User do
      public? true
      allow_nil? true
      attribute_writable? true
    end
  end

  # The row that belongs to nobody (auth disabled → everyone shares it).
  # A real user's row is keyed by the user's own id, so the primary key
  # gives us "at most one row per owner" for free.
  @global_id "00000000-0000-0000-0000-000000000000"

  @empty %{endpoint: "", model: "", api_key: nil}

  @doc """
  The full configuration for `actor` (nil → the global row), API key
  included. Server-side callers only (`Dala.Terminal.Speech`).
  """
  def config(actor) do
    case row(actor) do
      nil -> @empty
      row -> %{endpoint: row.endpoint || "", model: row.model || "", api_key: row.api_key}
    end
  end

  @doc "What the client is allowed to see: no API key, just whether one is set."
  def summary(actor) do
    config = config(actor)

    %{
      endpoint: config.endpoint,
      model: config.model,
      api_key_set: is_binary(config.api_key) and config.api_key != ""
    }
  end

  @doc """
  Upsert the actor's row. `args` may carry `:endpoint`, `:model`,
  `:api_key` and `:clear_api_key`; nil endpoint/model keep the stored value.
  """
  def save(actor, args) do
    row = row(actor)

    attrs = %{
      endpoint: pick(Map.get(args, :endpoint), row && row.endpoint, ""),
      model: pick(Map.get(args, :model), row && row.model, ""),
      api_key: api_key(args, row)
    }

    result =
      case row do
        nil ->
          attrs = Map.merge(attrs, %{id: owner_id(actor), user_id: actor_id(actor)})
          Ash.create(__MODULE__, attrs, action: :upsert, authorize?: false)

        row ->
          Ash.update(row, attrs, action: :put, authorize?: false)
      end

    with {:ok, saved} <- result do
      {:ok,
       %{
         endpoint: saved.endpoint,
         model: saved.model,
         api_key_set: is_binary(saved.api_key) and saved.api_key != ""
       }}
    end
  end

  defp api_key(args, row) do
    stored = row && row.api_key

    cond do
      Map.get(args, :clear_api_key) == true -> nil
      is_binary(Map.get(args, :api_key)) and Map.get(args, :api_key) != "" -> args.api_key
      true -> stored
    end
  end

  defp pick(new, stored, fallback)
  defp pick(new, _stored, _fallback) when is_binary(new), do: new
  defp pick(_new, stored, _fallback) when is_binary(stored), do: stored
  defp pick(_new, _stored, fallback), do: fallback

  # The actor's row, or the shared global row when nobody is signed in.
  # Lookups go through the owner-derived primary key: one user can never
  # even address another user's row.
  defp row(actor) do
    __MODULE__
    |> Ash.Query.filter(id == ^owner_id(actor))
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp owner_id(actor), do: actor_id(actor) || @global_id

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_actor), do: nil
end
