defmodule Dala.Agent.Session do
  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Agent,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshTypescript.Resource]

  sqlite do
    table "agent_sessions"
    repo Dala.Repo
  end

  typescript do
    type_name "AgentSession"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :cwd]

      change fn changeset, _context ->
        changeset
        |> default_attr(:cwd, System.user_home() || "/")
        |> default_attr(:name, "agent")
        |> Ash.Changeset.after_transaction(fn
          _cs, {:ok, session} ->
            case Dala.Agent.Server.start(session.id, session.cwd) do
              {:ok, _pid} ->
                {:ok, session}

              {:error, reason} ->
                {:error,
                 Ash.Error.Invalid.exception(errors: ["agent failed to start: #{inspect(reason)}"])}
            end

          _cs, other ->
            other
        end)
      end
    end

    update :rename do
      accept [:name]
    end

    update :mark_ready do
      change set_attribute(:status, :ready)
    end

    update :mark_exited do
      change set_attribute(:status, :exited)
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn
          cs, {:ok, result} ->
            Dala.Agent.Server.stop(cs.data.id)
            {:ok, result}

          _cs, other ->
            other
        end)
      end
    end

    action :prompt, :boolean do
      argument :id, :uuid, allow_nil?: false
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Agent.Server.prompt(input.arguments.id, input.arguments.text)
        {:ok, true}
      end
    end

    action :cancel, :boolean do
      argument :id, :uuid, allow_nil?: false

      run fn input, _context ->
        Dala.Agent.Server.cancel(input.arguments.id)
        {:ok, true}
      end
    end

    action :respond_permission, :boolean do
      argument :id, :uuid, allow_nil?: false
      argument :request_id, :integer, allow_nil?: false
      argument :option_id, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Agent.Server.respond_permission(
          input.arguments.id,
          input.arguments.request_id,
          input.arguments.option_id
        )

        {:ok, true}
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :cwd, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:starting, :ready, :exited]
      default :starting
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at do
      public? true
    end
  end

  defp default_attr(changeset, attr, value) do
    case Ash.Changeset.get_attribute(changeset, attr) do
      v when v in [nil, ""] -> Ash.Changeset.force_change_attribute(changeset, attr, value)
      _ -> changeset
    end
  end
end
