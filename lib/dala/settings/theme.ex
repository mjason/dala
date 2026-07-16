defmodule Dala.Settings.Theme do
  @moduledoc """
  A custom terminal/UI theme: a named colour override on top of one of the two
  base palettes (`:light` / `:dark`). Themes form a per-user (plus anonymous-
  global) LIBRARY — unlike `Dala.Settings.Speech`, one owner has MANY themes.

  Isolation mirrors `Dala.Settings.Speech` exactly: every row carries a
  non-null `owner_id` — the actor's user id when signed in, or a sentinel uuid
  (`#{"00000000-0000-0000-0000-000000000000"}`) for the shared anonymous/global
  library used when authentication is off. Scoping and the per-owner name
  uniqueness both key off `owner_id`, so SQLite (which cannot do `NULLS NOT
  DISTINCT`) still enforces "one name per owner" for the global rows too. The
  whole app runs `authorize? false`; isolation is manual scoping, not policy.

  `tokens` is the sparse colour map — see `Dala.Settings.Theme.Tokens` for the
  45-key contract and the write-time whitelist. Six `builtin` presets ship as
  non-destructible global rows (`Dala.Settings.Theme.Presets`); users may fork
  them (copy tokens into a new owned row) but never edit or delete them.
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Settings,
    data_layer: AshSqlite.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshTypescript.Resource]

  require Ash.Query

  # The owner of every anonymous row (auth off → everyone shares this library).
  # A signed-in user's rows are keyed by their own user id instead. Non-null on
  # purpose: it is the uniqueness/scoping key, and SQLite treats each NULL as
  # distinct, which would let duplicate "global" names slip through.
  @global_id "00000000-0000-0000-0000-000000000000"

  sqlite do
    table "custom_themes"
    repo Dala.Repo

    references do
      # A user's themes are meaningless without the user; the FK cascades on
      # delete so a removed account takes its library with it (global presets,
      # owned by nobody, survive).
      reference :user, on_delete: :delete
    end
  end

  typescript do
    type_name "CustomTheme"
  end

  actions do
    # Internal, unscoped read — NEVER exposed via typescript_rpc (it would leak
    # every owner's library). RPC clients use :list / :get, which scope to the
    # actor. Kept for server-side/test use.
    defaults [:read]

    read :list do
      description "The caller's themes plus the global/built-in library, built-ins first."
      prepare fn query, context -> scope(query, context.actor) end
      prepare build(sort: [builtin: :desc, name: :asc])
    end

    read :get do
      description "A single theme by id, scoped to the caller's visibility."
      get_by :id
      prepare fn query, context -> scope(query, context.actor) end
    end

    create :create do
      description "Create a theme owned by the caller (or the global library when anonymous)."
      primary? true
      accept [:name, :base, :tokens]

      # owner_id/user_id are DERIVED from the actor, never accepted — a client
      # cannot plant a row in someone else's (or the global) library.
      change fn changeset, context ->
        actor = context.actor

        changeset
        |> Ash.Changeset.force_change_attribute(:owner_id, owner_id(actor))
        |> Ash.Changeset.force_change_attribute(:user_id, actor && actor.id)
      end

      change fn changeset, _context -> clean_tokens(changeset) end
    end

    update :update do
      description "Edit one of the caller's own themes. Built-ins and others' themes are forbidden."
      require_atomic? false
      accept [:name, :base, :tokens]

      change fn changeset, context -> guard_writable(changeset, context.actor) end
      change fn changeset, _context -> clean_tokens(changeset) end
    end

    destroy :destroy do
      description "Delete one of the caller's own themes. Built-ins and others' themes are forbidden."
      primary? true
      require_atomic? false

      change fn changeset, context -> guard_writable(changeset, context.actor) end
    end

    # Internal seeding action for the six built-in presets. NEVER exposed via
    # typescript_rpc: it accepts id/owner_id/user_id/builtin, so exposing it
    # would let a client forge a global built-in. Upserts by the preset's fixed
    # id so a version bump refreshes colours without touching user forks.
    create :seed_preset do
      accept [:id, :owner_id, :user_id, :name, :base, :builtin, :tokens]
      upsert? true
      upsert_fields [:name, :base, :builtin, :tokens]
    end
  end

  pub_sub do
    module DalaWeb.Endpoint

    publish :create, ["settings"],
      event: "theme_created",
      public?: true,
      returns: :map,
      constraints: [fields: Dala.Settings.Theme.Payloads.summary_fields()],
      transform: &Dala.Settings.Theme.Payloads.summary/1

    publish :update, ["settings"],
      event: "theme_updated",
      public?: true,
      returns: :map,
      constraints: [fields: Dala.Settings.Theme.Payloads.summary_fields()],
      transform: &Dala.Settings.Theme.Payloads.summary/1

    publish :destroy, ["settings"],
      event: "theme_deleted",
      public?: true,
      returns: :map,
      constraints: [fields: Dala.Settings.Theme.Payloads.deleted_fields()],
      transform: &Dala.Settings.Theme.Payloads.deleted/1
  end

  attributes do
    # Writable so the preset seeder can plant fixed ids; the public :create
    # action does NOT accept :id, so user themes still get a generated uuid.
    uuid_primary_key :id, writable?: true, public?: true

    attribute :owner_id, :uuid do
      description "The library this theme belongs to: a user's id, or the global sentinel."
      public? true
      allow_nil? false
    end

    attribute :name, :string do
      public? true
      allow_nil? false
      constraints max_length: 200
    end

    attribute :base, :atom do
      description "Which base palette omitted tokens fall back to on the client."
      public? true
      allow_nil? false
      constraints one_of: [:light, :dark]
    end

    attribute :builtin, :boolean do
      description "Shipped preset: selectable and forkable, but never editable or deletable."
      public? true
      allow_nil? false
      default false
    end

    attribute :tokens, :map do
      description "Sparse colour overrides — see Dala.Settings.Theme.Tokens for the 45-key contract."
      public? true
      allow_nil? false
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :user, Dala.Accounts.User do
      public? true
      allow_nil? true
      attribute_writable? true
    end
  end

  identities do
    # One name per owner. Because owner_id is non-null (global rows share the
    # sentinel), two global themes named the same collide here — the sentinel
    # is what buys us NULLS-NOT-DISTINCT behaviour SQLite won't give us.
    identity :unique_name_per_owner, [:owner_id, :name]
  end

  @doc "The sentinel owner id for the anonymous/global library."
  def global_id, do: @global_id

  @doc "The owner id for `actor`: their user id, or the global sentinel when anonymous."
  def owner_id(actor), do: (actor && actor.id) || @global_id

  @doc "Idempotently seed the six built-in presets (see `Dala.Settings.Theme.Presets`)."
  def ensure_builtin_presets, do: Dala.Settings.Theme.Presets.ensure!()

  @doc false
  # Restrict a read to what `actor` may see: their own rows plus the global
  # library.
  def scope(query, actor) do
    owner = owner_id(actor)
    global = @global_id
    Ash.Query.filter(query, owner_id == ^owner or owner_id == ^global)
  end

  @doc false
  # Validate/normalise tokens on write; reject unknown keys and non-string
  # values (an :invalid error, distinct from the :forbidden ownership guard).
  def clean_tokens(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :tokens) do
      case Dala.Settings.Theme.Tokens.validate(Ash.Changeset.get_attribute(changeset, :tokens)) do
        {:ok, clean} -> Ash.Changeset.force_change_attribute(changeset, :tokens, clean)
        {:error, message} -> Ash.Changeset.add_error(changeset, field: :tokens, message: message)
      end
    else
      changeset
    end
  end

  @doc false
  # Forbid mutating a built-in preset or a row outside the caller's scope.
  def guard_writable(changeset, actor) do
    record = changeset.data

    cond do
      record.builtin ->
        Ash.Changeset.add_error(
          changeset,
          Dala.Settings.Theme.Errors.Forbidden.exception(
            message: "built-in presets cannot be modified or deleted"
          )
        )

      record.owner_id != owner_id(actor) ->
        Ash.Changeset.add_error(
          changeset,
          Dala.Settings.Theme.Errors.Forbidden.exception(
            message: "theme belongs to another owner"
          )
        )

      true ->
        changeset
    end
  end
end
