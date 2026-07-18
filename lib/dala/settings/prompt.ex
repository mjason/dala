defmodule Dala.Settings.Prompt do
  @moduledoc """
  The prompt stash: quick capture for prompts and ideas, quick recall when
  needed. Using one (inserting it into the composer) archives it — the stash
  is a queue of things you still intend to use, the archive is its history.

  Exposed both to the web UI (composer stash panel via `/rpc/run`) and to
  MCP (`Dala.Mcp.Registry` derives tools from the `typescript_rpc` surface),
  so any agent connected to this dala can capture an idea from anywhere.

  Ownership mirrors `Dala.Settings.Theme`: rows are scoped per user via a
  non-null `owner_id` (the actor's user id, or a sentinel uuid for the
  anonymous/global scope used by no-auth installs and MCP's nil actor).
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Settings,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  require Ash.Query

  # Fixed sentinel for "no user": the shared global scope.
  @global_id "00000000-0000-0000-0000-000000000000"

  sqlite do
    table "prompt_stash"
    repo Dala.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  typescript do
    type_name "Prompt"
  end

  actions do
    # Unscoped read for server-side/test use — NEVER expose via typescript_rpc.
    defaults [:read]

    read :list do
      description """
      List the caller's prompt stash: stashed (not yet used) entries first,
      newest first within each status. Archived entries are the usage history.
      """

      prepare fn query, context -> scope(query, context.actor) end
      # Atoms sort as text and "stashed" > "archived", so :desc puts the
      # live stash before the archive.
      prepare build(sort: [status: :desc, updated_at: :desc])
    end

    create :stash do
      description """
      Save a prompt or idea into the stash for later use. Use this for quick
      capture: pass the full prompt text as `content`.
      """

      accept [:content]

      change fn changeset, context ->
        actor = context.actor

        changeset
        |> Ash.Changeset.force_change_attribute(:owner_id, owner_id(actor))
        |> Ash.Changeset.force_change_attribute(:user_id, actor && actor.id)
      end
    end

    update :archive do
      description """
      Mark a stashed prompt as used: it moves from the stash into the
      archive (with a used-at timestamp). Call after consuming a prompt.
      """

      require_atomic? false
      change fn changeset, context -> guard_writable(changeset, context.actor) end
      change set_attribute(:status, :archived)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :used_at, DateTime.utc_now())
      end
    end

    update :restore do
      description "Move an archived prompt back into the live stash."

      require_atomic? false
      change fn changeset, context -> guard_writable(changeset, context.actor) end
      change set_attribute(:status, :stashed)
      change set_attribute(:used_at, nil)
    end

    update :edit do
      description "Rewrite a prompt's text (stashed or archived)."

      accept [:content]
      require_atomic? false
      change fn changeset, context -> guard_writable(changeset, context.actor) end
    end

    destroy :destroy do
      description "Delete a prompt from the stash or archive permanently."
      primary? true
      require_atomic? false

      change fn changeset, context -> guard_writable(changeset, context.actor) end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :content, :string do
      description "The prompt text itself."
      constraints max_length: 20_000, trim?: false, allow_empty?: false
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:stashed, :archived]
      default :stashed
      allow_nil? false
      public? true
    end

    attribute :used_at, :utc_datetime_usec do
      description "When the prompt was last consumed (archived)."
      public? true
    end

    # Non-null scope key (mirrors Theme): actor's user id or the sentinel.
    attribute :owner_id, :uuid do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at do
      public? true
    end

    update_timestamp :updated_at do
      public? true
    end
  end

  relationships do
    belongs_to :user, Dala.Accounts.User do
      public? true
      allow_nil? true
      attribute_writable? true
    end
  end

  @doc "The owner id for `actor`: their user id, or the global sentinel when anonymous."
  def owner_id(actor), do: (actor && actor.id) || @global_id

  @doc false
  # Restrict a read to the caller's own rows.
  def scope(query, actor) do
    owner = owner_id(actor)
    Ash.Query.filter(query, owner_id == ^owner)
  end

  @doc false
  # Forbid mutating a row outside the caller's scope (manual scoping — the
  # app runs `authorize? false`, see `Dala.Settings.Theme.Errors.Forbidden`).
  def guard_writable(changeset, actor) do
    if changeset.data.owner_id == owner_id(actor) do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        Dala.Settings.Theme.Errors.Forbidden.exception(message: "prompt belongs to another owner")
      )
    end
  end
end
