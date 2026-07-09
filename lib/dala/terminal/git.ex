defmodule Dala.Terminal.Git do
  @moduledoc """
  Generic actions backing the git panel. No data layer — everything shells
  out to `git` via `Dala.Terminal.GitOps`.
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Terminal,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name "Git"
  end

  actions do
    action :git_status, :map do
      description "Working-tree status of the repository containing a path."

      constraints fields: [
                    repo: [type: :boolean, allow_nil?: false],
                    root: [type: :string],
                    branch: [type: :string],
                    files: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            path: [type: :string, allow_nil?: false],
                            status: [type: :string, allow_nil?: false],
                            staged: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _context ->
        {:ok, Dala.Terminal.GitOps.status(input.arguments.path)}
      end
    end

    action :git_diff, :map do
      description "Unified diff of one file against HEAD (untracked = fully added)."

      constraints fields: [
                    diff: [type: :string, allow_nil?: false],
                    binary: [type: :boolean, allow_nil?: false],
                    truncated: [type: :boolean, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false
      argument :file, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.diff(input.arguments.path, input.arguments.file)
      end
    end

    action :git_stage, :boolean do
      description "Stage one file."
      argument :path, :string, allow_nil?: false
      argument :file, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.stage(input.arguments.path, input.arguments.file)
      end
    end

    action :git_unstage, :boolean do
      description "Unstage one file, keeping worktree changes."
      argument :path, :string, allow_nil?: false
      argument :file, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.unstage(input.arguments.path, input.arguments.file)
      end
    end

    action :git_discard, :boolean do
      description "Discard all changes to one file (untracked files are deleted)."
      argument :path, :string, allow_nil?: false
      argument :file, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.discard(input.arguments.path, input.arguments.file)
      end
    end

    action :git_commit, :map do
      description "Commit the staged changes."

      constraints fields: [hash: [type: :string, allow_nil?: false]]

      argument :path, :string, allow_nil?: false
      argument :message, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.commit(input.arguments.path, input.arguments.message)
      end
    end

    action :git_log, :map do
      description "Recent commits, newest first."

      constraints fields: [
                    commits: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            hash: [type: :string, allow_nil?: false],
                            author: [type: :string, allow_nil?: false],
                            date: [type: :string, allow_nil?: false],
                            subject: [type: :string, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      argument :limit, :integer do
        default 50
        constraints min: 1, max: 200
      end

      run fn input, _context ->
        Dala.Terminal.GitOps.log(input.arguments.path, input.arguments.limit)
      end
    end

    action :git_show, :map do
      description "Full patch of one commit."

      constraints fields: [
                    text: [type: :string, allow_nil?: false],
                    truncated: [type: :boolean, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false
      argument :hash, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.show(input.arguments.path, input.arguments.hash)
      end
    end

    action :git_branches, :map do
      description "Local and remote branches, plus the current branch."

      constraints fields: [
                    current: [type: :string],
                    local: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            name: [type: :string, allow_nil?: false],
                            current: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ],
                    remote: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            name: [type: :string, allow_nil?: false],
                            current: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.branches(input.arguments.path)
      end
    end

    action :git_checkout, :boolean do
      description "Switch to a branch (remote branches become local tracking branches)."
      argument :path, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false

      run fn input, _context ->
        Dala.Terminal.GitOps.checkout(input.arguments.path, input.arguments.name)
      end
    end
  end
end
