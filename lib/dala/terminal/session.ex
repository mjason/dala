defmodule Dala.Terminal.Session do
  @moduledoc """
  A terminal session: one shell (running in an out-of-process PTY holder,
  driven by `Dala.Terminal.Server`) plus its metadata — name, cwd, status,
  scrollback limit. Lifecycle actions publish typed PubSub events consumed
  by the sessions lobby and the per-session terminal channel; the declared
  `notify_*` actions exist only so those broadcast payloads are typed.
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Terminal,
    data_layer: AshSqlite.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshTypescript.Resource]

  sqlite do
    table "terminal_sessions"
    repo Dala.Repo
  end

  typescript do
    type_name "Session"
  end

  actions do
    defaults [:read]

    read :list do
      description "All sessions in sidebar order: position, then inserted_at."
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end

    create :create do
      accept [:scrollback_limit, :ephemeral]

      # Optional; SetDefaults falls back to $SHELL, $HOME and a cwd-based name.
      argument :name, :string
      argument :shell, :string
      argument :cwd, :string

      # Optional stable device id of the CREATING client: stamped as the
      # size owner at creation so no other device can win the first-attach
      # adoption race (see StampCreatorDevice). Omitted → nil, and the
      # first device to ever attach adopts (legacy/API fallback).
      argument :device_id, :string

      change Dala.Terminal.Session.Changes.SetDefaults
      change Dala.Terminal.Session.Changes.StampCreatorDevice
      change Dala.Terminal.Session.Changes.AppendPosition
      change Dala.Terminal.Session.Changes.StartServer
    end

    update :rename do
      accept [:name]
    end

    update :reorder do
      description """
      Move the session in the sidebar: before the session `before_id`, or to
      the end when `before_id` is omitted. Persisted server-side so every
      device sees the same order (last write wins on races).
      """

      argument :before_id, :uuid
      require_atomic? false
      change Dala.Terminal.Session.Changes.Reorder
    end

    update :set_scrollback_limit do
      accept [:scrollback_limit]
      require_atomic? false
      change Dala.Terminal.Session.Changes.ApplyScrollbackLimit
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change Dala.Terminal.Session.Changes.CleanupSession
    end

    action :foreground_app, :map do
      description "The CLI agent running in the session's foreground, if any."

      argument :id, :uuid, allow_nil?: false

      constraints fields: [
                    app: [type: :string, allow_nil?: false],
                    cmdline: [type: :string, allow_nil?: false]
                  ]

      run fn input, _context ->
        Dala.Terminal.Server.foreground_app(input.arguments.id)
      end
    end

    action :agent_commands, :map do
      description "Slash commands available in the session's foreground agent."

      argument :id, :uuid, allow_nil?: false

      constraints fields: [
                    app: [type: :string, allow_nil?: false],
                    commands: [
                      type: {:array, Ash.Type.Map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            name: [type: :string, allow_nil?: false],
                            description: [type: :string, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn input, _context ->
        with {:ok, %{app: app}} <- Dala.Terminal.Server.foreground_app(input.arguments.id) do
          session = Dala.Terminal.get_session!(input.arguments.id)
          {:ok, %{app: app, commands: Dala.Terminal.AgentCommands.list(app, session.cwd)}}
        end
      end
    end

    action :kick_viewers, :map do
      description """
      Detach other zellij/tmux clients of the multiplexer session this
      terminal's shell is attached to — they cap it to the smallest window.
      """

      argument :id, :uuid, allow_nil?: false

      constraints fields: [
                    multiplexer: [type: :string, allow_nil?: false],
                    session: [type: :string, allow_nil?: false],
                    kicked: [type: :integer, allow_nil?: false],
                    error: [type: :string]
                  ]

      # Always {:ok, map}: failure reasons ride in the :error field, because
      # plain {:error, string} results are classed :unknown and the RPC layer
      # hides their message from clients.
      run fn input, _context ->
        case Dala.Terminal.Server.kick_viewers(input.arguments.id) do
          {:ok, result} -> {:ok, Map.put(result, :error, nil)}
          {:error, message} -> {:ok, %{multiplexer: "", session: "", kicked: 0, error: message}}
        end
      end
    end

    action :close, :boolean do
      description "Kill the shell of a running session. Scrollback is kept."
      argument :id, :uuid, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.Server.stop(input.arguments.id)
        {:ok, true}
      end
    end

    action :restart, :boolean do
      description "Respawn the shell of an exited session, keeping its scrollback."
      argument :id, :uuid, allow_nil?: false

      run fn input, _context ->
        session = Dala.Terminal.get_session!(input.arguments.id)

        # A fresh shell starts with fresh size ownership: whatever device
        # restarts it adopts on first resize, instead of the pre-exit owner
        # locking everyone else into follower mode for a PTY it may never
        # attach to again. Only when the shell is really gone — a restart
        # racing an already-running server must not desync the server's
        # in-memory ownership from the record.
        session =
          if Dala.Terminal.Server.alive?(input.arguments.id) do
            session
          else
            case Dala.Terminal.set_size_owner_device(session, %{size_owner_device: nil}) do
              {:ok, cleared} -> cleared
              {:error, _error} -> session
            end
          end

        case Dala.Terminal.Server.ensure_started(session) do
          {:ok, _pid} -> {:ok, true}
          {:error, reason} -> {:error, "could not start terminal: #{inspect(reason)}"}
        end
      end
    end

    # Internal actions, invoked by Dala.Terminal.Server.
    update :mark_running do
      change set_attribute(:status, :running)
      change set_attribute(:exit_code, nil)
    end

    update :mark_exited do
      argument :exit_code, :integer
      change set_attribute(:status, :exited)
      change atomic_update(:exit_code, expr(^arg(:exit_code)))
    end

    update :update_cwd do
      accept [:cwd]
    end

    # Internal: PTY size ownership memory (see Dala.Terminal.Server). The
    # session remembers which DEVICE drives its size across reconnects and
    # restarts; only an explicit claim_size transfers it.
    update :set_size_owner_device do
      accept [:size_owner_device]
    end

    # Internal: used by Changes.Reorder when float positions run out of gap.
    update :set_position do
      accept [:position]
    end

    # These two exist only so the typed-channel publications below have an
    # action to attach to; they are never invoked (see the pub_sub comment).
    update :notify_output do
      require_atomic? false
    end

    update :notify_replay do
      require_atomic? false
    end

    update :notify_agent do
      require_atomic? false
    end
  end

  @doc """
  Emulator history lines for a stored `scrollback_limit`. Values above 100k
  are legacy byte limits from the retired DETS cache (~120 bytes/line
  converts them); results clamp to 1_000..50_000, defaulting to 10_000.
  """
  def history_lines(limit) when is_integer(limit) and limit > 100_000,
    do: (limit / 120) |> round() |> max(1_000) |> min(50_000)

  def history_lines(limit) when is_integer(limit) and limit > 0,
    do: limit |> max(1_000) |> min(50_000)

  def history_lines(_other), do: 10_000

  pub_sub do
    module DalaWeb.Endpoint

    publish :create, ["sessions"],
      event: "session_created",
      public?: true,
      returns: :map,
      constraints: [fields: Dala.Terminal.Session.Payloads.summary_fields()],
      transform: &Dala.Terminal.Session.Payloads.summary/1

    # set_size_owner_device changes nothing the summary payload carries —
    # broadcasting it would only churn every client's session list on each
    # ownership adoption/claim, so it is excluded.
    publish_all :update, ["sessions"],
      event: "session_updated",
      public?: true,
      returns: :map,
      constraints: [fields: Dala.Terminal.Session.Payloads.summary_fields()],
      transform: &Dala.Terminal.Session.Payloads.summary/1,
      except: [:set_size_owner_device]

    publish :destroy, ["sessions"],
      event: "session_deleted",
      public?: true,
      returns: :map,
      constraints: [fields: [id: [type: :uuid, allow_nil?: false]]],
      transform: &Dala.Terminal.Session.Payloads.deleted/1

    publish :mark_exited, ["terminal", :id],
      event: "exit",
      public?: true,
      returns: :map,
      constraints: [
        fields: [id: [type: :uuid, allow_nil?: false], exitCode: [type: :integer]]
      ],
      transform: &Dala.Terminal.Session.Payloads.exit_summary/1

    publish :update_cwd, ["terminal", :id],
      event: "cwd",
      public?: true,
      returns: :map,
      constraints: [
        fields: [id: [type: :uuid, allow_nil?: false], cwd: [type: :string, allow_nil?: false]]
      ],
      transform: &Dala.Terminal.Session.Payloads.cwd_summary/1

    # These two publications are never triggered through Ash actions: the
    # terminal server broadcasts "output"/"replay" events with this exact
    # payload shape straight to the endpoint (one DB write per output chunk
    # would be prohibitive). They are declared here so AshTypescript's typed
    # channel codegen knows the events and their payload types.
    publish :notify_output, ["terminal", :id],
      event: "output",
      public?: true,
      returns: :map,
      constraints: [
        fields: [
          data: [type: :string, allow_nil?: false],
          seq: [type: :integer, allow_nil?: false]
        ]
      ],
      transform: fn _notification -> %{data: "", seq: 0} end

    publish :notify_agent, ["sessions"],
      event: "agent_event",
      public?: true,
      returns: :map,
      constraints: [
        fields: [
          id: [type: :string, allow_nil?: false],
          agent: [type: :string, allow_nil?: false],
          event: [type: :string, allow_nil?: false],
          project: [type: :string],
          summary: [type: :string],
          query: [type: :string],
          response: [type: :string],
          toolName: [type: :string],
          toolInput: [type: :string]
        ]
      ],
      transform: fn _notification -> %{id: "", agent: "", event: ""} end

    publish :notify_replay, ["terminal", :id],
      event: "replay",
      public?: true,
      returns: :map,
      constraints: [
        fields: [
          data: [type: :string, allow_nil?: false],
          seq: [type: :integer, allow_nil?: false],
          done: [type: :boolean, allow_nil?: false]
        ]
      ],
      transform: fn _notification -> %{data: "", seq: 0, done: true} end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      # Ash's string type trims and rejects the empty string by default, so a
      # blank rename is refused; the cap keeps a pathological paste (or an API
      # caller) from stuffing a novel into the sidebar. Validated on write —
      # rows created before the cap are untouched.
      constraints max_length: 200
      allow_nil? false
      public? true
    end

    attribute :shell, :string do
      allow_nil? false
      public? true
    end

    attribute :cwd, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:running, :exited]
      default :running
      allow_nil? false
      public? true
    end

    attribute :exit_code, :integer do
      public? true
    end

    attribute :scrollback_limit, :integer do
      description """
      History lines kept by the holder's terminal emulator (applied when the
      shell is next started). Values above 100k are legacy byte limits from
      the retired DETS cache and are converted on use.
      """

      constraints min: 1_000, max: 268_435_456
      default 10_000
      allow_nil? false
      public? true
    end

    attribute :position, :float do
      description """
      Sidebar sort key. Floats make reordering a single-row write (midpoint
      between the new neighbours); `Changes.Reorder` renormalizes to 1.0..n
      when a gap underflows. Ties sort by inserted_at.
      """

      default 0.0
      allow_nil? false
      public? true
    end

    attribute :size_owner_device, :string do
      description """
      Stable device id (frontend-generated, localStorage) of the client that
      owns this session's PTY size. Adopted by the first device to ever
      attach; transferred only by an explicit claim_size. Other devices
      render as followers even when the owner is offline.
      """
    end

    attribute :ephemeral, :boolean do
      description """
      Quick shells: the session destroys itself (instead of lingering as
      exited) when its shell exits, so `exit`/Ctrl+D closes it for good.
      """

      default false
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
end
