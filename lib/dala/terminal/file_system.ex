defmodule Dala.Terminal.FileSystem do
  @moduledoc """
  Generic actions backing the drawer file manager: directory listings and
  small file previews. No data layer — everything reads the host filesystem.
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Terminal,
    extensions: [AshTypescript.Resource]

  @preview_default_max_bytes 262_144
  @write_max_bytes 10 * 1024 * 1024
  # Base64 inflates by 4/3 and the whole payload must fit the RPC body limit
  # (Plug.Parsers defaults to 8 MB), so cap pasted files at 5 MB.
  @paste_max_bytes 5 * 1024 * 1024

  typescript do
    type_name "FileSystem"
  end

  actions do
    action :list_directory, :map do
      description "List the entries of a directory on the host."

      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    parent: [type: :string],
                    entries: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            name: [type: :string, allow_nil?: false],
                            type: [type: :string, allow_nil?: false],
                            symlink: [type: :boolean, allow_nil?: false],
                            size: [type: :integer, allow_nil?: false],
                            mtime: [type: :utc_datetime_usec]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _context ->
        path = expand(input.arguments.path)

        case File.ls(path) do
          {:ok, names} ->
            entries =
              names
              |> Enum.map(&entry(path, &1))
              |> Enum.sort_by(fn entry ->
                {entry.type != "directory", String.downcase(entry.name)}
              end)

            parent = if path == "/", do: nil, else: Path.dirname(path)
            {:ok, %{path: path, parent: parent, entries: entries}}

          {:error, reason} ->
            {:error, "cannot list #{path}: #{:file.format_error(reason)}"}
        end
      end
    end

    action :list_files, :map do
      description """
      Recursively list file paths under a root, for the quick-open palette
      and composer @-mentions. Inside a git work tree the list comes from
      `git ls-files` (tracked + untracked, `.gitignore` respected); elsewhere
      a bounded manual walk skips hidden directories and common
      dependency/build trees. Both are capped, with `truncated` reporting
      whether the cap was hit.
      """

      constraints fields: [
                    root: [type: :string, allow_nil?: false],
                    files: [type: {:array, :string}, allow_nil?: false],
                    truncated: [type: :boolean, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _context ->
        root = expand(input.arguments.path)

        if File.dir?(root) do
          {files, truncated} = list_files_under(root)
          {:ok, %{root: root, files: files, truncated: truncated}}
        else
          {:error, "not a directory: #{root}"}
        end
      end
    end

    action :read_file, :map do
      description "Read a file preview (truncated, text only)."

      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    size: [type: :integer, allow_nil?: false],
                    truncated: [type: :boolean, allow_nil?: false],
                    binary: [type: :boolean, allow_nil?: false],
                    content: [type: :string]
                  ]

      argument :path, :string, allow_nil?: false

      argument :max_bytes, :integer do
        default @preview_default_max_bytes
        constraints min: 1, max: 2_097_152
      end

      run fn input, _context ->
        path = expand(input.arguments.path)
        max_bytes = input.arguments.max_bytes

        with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
             {:ok, data} <- read_head(path, max_bytes) do
          case to_text(data) do
            {:ok, text} ->
              {:ok,
               %{
                 path: path,
                 size: size,
                 truncated: size > max_bytes,
                 binary: false,
                 content: text
               }}

            :binary ->
              {:ok, %{path: path, size: size, truncated: false, binary: true, content: nil}}
          end
        else
          {:ok, %File.Stat{}} -> {:error, "#{path} is not a regular file"}
          {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
        end
      end
    end

    action :write_file, :map do
      description "Overwrite a text file with new content."

      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    size: [type: :integer, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false

      # trim?/allow_empty? matter: editors must be able to save trailing
      # whitespace/newlines and to empty a file.
      argument :content, :string do
        allow_nil? false
        constraints trim?: false, allow_empty?: true
      end

      run fn input, _context ->
        path = expand(input.arguments.path)
        content = input.arguments.content

        cond do
          byte_size(content) > @write_max_bytes ->
            {:error, "file too large to save (max #{div(@write_max_bytes, 1_048_576)} MB)"}

          File.dir?(path) ->
            {:error, "#{path} is a directory"}

          true ->
            case File.write(path, content) do
              :ok -> {:ok, %{path: path, size: byte_size(content)}}
              {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
            end
        end
      end
    end

    action :delete_entry, :map do
      description "Delete a file, or a directory with everything in it."

      constraints fields: [path: [type: :string, allow_nil?: false]]

      argument :path, :string, allow_nil?: false

      run fn input, _context ->
        path = expand(input.arguments.path)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            case File.rm_rf(path) do
              {:ok, _removed} ->
                {:ok, %{path: path}}

              {:error, reason, at} ->
                {:error, "cannot delete #{at}: #{:file.format_error(reason)}"}
            end

          {:ok, _stat} ->
            case File.rm(path) do
              :ok -> {:ok, %{path: path}}
              {:error, reason} -> {:error, "cannot delete #{path}: #{:file.format_error(reason)}"}
            end

          {:error, reason} ->
            {:error, "cannot delete #{path}: #{:file.format_error(reason)}"}
        end
      end
    end

    action :lsp_servers, :map do
      description """
      Language servers that should attach to a file: resolved per project
      root (git toplevel of the file's directory), project-local installs
      first, plus workspace extras like dark-magician's `dm lsp`.
      """

      constraints fields: [
                    root: [type: :string, allow_nil?: false],
                    language: [type: :string],
                    servers: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            id: [type: :integer, allow_nil?: false],
                            name: [type: :string, allow_nil?: false],
                            initializationOptions: [type: :map],
                            settings: [type: :map]
                          ]
                        ]
                      ]
                    ],
                    checked: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            path: [type: :string, allow_nil?: false],
                            found: [type: :boolean, allow_nil?: false]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _context ->
        path = Path.expand(input.arguments.path)
        probe = Dala.Lsp.Discovery.probe_file(path)

        servers =
          for server <- probe.servers do
            %{
              id: server.id,
              name: server.name,
              initializationOptions: server.initialization_options,
              settings: server.settings
            }
          end

        {:ok,
         %{root: probe.root, language: probe.language, servers: servers, checked: probe.checked}}
      end
    end

    action :save_pasted_file, :map do
      description """
      Persist a file pasted or dropped into the web terminal (typically a
      screenshot) to a temp directory, returning its absolute path so it can
      be handed to CLI tools like Claude Code as a file reference.
      """

      constraints fields: [
                    path: [type: :string, allow_nil?: false],
                    size: [type: :integer, allow_nil?: false]
                  ]

      # Original filename or MIME hint; only its extension is kept.
      argument :name, :string, allow_nil?: false

      argument :content_base64, :string do
        allow_nil? false
        constraints trim?: false
      end

      run fn input, _context ->
        with {:ok, content} <- Base.decode64(input.arguments.content_base64),
             :ok <- check_paste_size(content) do
          dir = Path.join(System.tmp_dir!(), "dala-paste")
          File.mkdir_p!(dir)

          timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
          rand = Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
          path = Path.join(dir, "paste-#{timestamp}-#{rand}.#{safe_ext(input.arguments.name)}")

          case File.write(path, content) do
            :ok ->
              File.chmod(path, 0o600)
              {:ok, %{path: path, size: byte_size(content)}}

            {:error, reason} ->
              {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
          end
        else
          :error -> {:error, "invalid base64 content"}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  defp check_paste_size(content) do
    if byte_size(content) > @paste_max_bytes do
      {:error, "pasted file too large (max #{div(@paste_max_bytes, 1_048_576)} MB)"}
    else
      :ok
    end
  end

  # "screenshot.png" -> "png", "image/png" -> "png"; anything else -> "png".
  defp safe_ext(name) do
    ext =
      case Path.extname(name) do
        "." <> ext ->
          ext

        "" ->
          case String.split(name, "/") do
            [type, subtype] when type in ~w(image video audio application text) -> subtype
            _not_a_mime -> ""
          end
      end

    if ext =~ ~r/^[a-zA-Z0-9]{1,8}$/, do: String.downcase(ext), else: "png"
  end

  # Quick-open walk bounds: enough for real projects, bounded for $HOME.
  @walk_max_files 20_000
  @walk_max_depth 12
  @walk_skip_dirs MapSet.new(
                    ~w(node_modules _build deps target .git .hg .svn __pycache__ .venv venv)
                  )

  # Give a slow git (cold network filesystem, gigantic index) a bounded
  # budget before falling back to the manual walk.
  @git_files_timeout_ms 3_000
  defp git_files_timeout_ms,
    do: Application.get_env(:dala, :list_files_git_timeout_ms, @git_files_timeout_ms)

  # Inside a git work tree the index is the authority — `.gitignore`
  # respected, no junk eating the cap, deterministic order. Everywhere else
  # (or when git errors out or exceeds its deadline): the bounded manual walk.
  defp list_files_under(root) do
    case git_files(root) do
      {:ok, listing} -> listing
      :error -> walk_files(root)
    end
  end

  # The whole git interaction runs in a task with a hard deadline: a hung
  # git must not wedge the RPC. Killing the task closes its port, which
  # detaches the external process.
  defp git_files(root) do
    task = Task.async(fn -> run_git_files(root) end)

    case Task.yield(task, git_files_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, listing}} -> {:ok, listing}
      _timeout_or_git_failure -> :error
    end
  end

  # Run from `root` itself (not the toplevel): git scopes the listing to the
  # current directory and reports paths relative to it, which is exactly what
  # subdirectory sessions need. `-z` gives raw NUL-separated bytes (no quoting
  # of non-ASCII names).
  defp run_git_files(root) do
    with top when is_binary(top) <- Dala.Paths.git_toplevel(root),
         {out, 0} <-
           System.cmd(
             "git",
             ["-C", root, "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
             stderr_to_stdout: false
           ) do
      {:ok, take_git_files(out, @walk_max_files, 0, [])}
    else
      _not_a_repo_or_git_failed -> :error
    end
  rescue
    _missing_git -> :error
  end

  # Counting parse: stops at the cap instead of materializing + sorting the
  # whole list (git already emits paths lexicographically sorted). Dropped
  # entries: trailing "/" (untracked nested repositories are printed as
  # directories, not files) and invalid UTF-8 (cannot round-trip through
  # JSON). Known limitation, accepted: gitlinks (committed submodules) and
  # index entries whose file was deleted on disk still appear — filtering
  # them out would cost one stat per path (up to 20k stats), too slow here.
  defp take_git_files(<<>>, _max, _count, acc), do: {Enum.reverse(acc), false}

  defp take_git_files(bin, max, count, acc) do
    {entry, rest} =
      case :binary.split(bin, <<0>>) do
        [entry, rest] -> {entry, rest}
        [entry] -> {entry, <<>>}
      end

    cond do
      entry == "" or String.ends_with?(entry, "/") or not String.valid?(entry) ->
        take_git_files(rest, max, count, acc)

      count >= max ->
        {Enum.reverse(acc), true}

      true ->
        take_git_files(rest, max, count + 1, [entry | acc])
    end
  end

  # The walk collects up to cap+1 entries so `truncated` means "there was
  # more" (strict `>`), matching the git path's semantics — hitting the cap
  # exactly is not truncation.
  defp walk_files(root) do
    {files, count} = walk_files(root, "", 0, [], 0)
    truncated = count > @walk_max_files
    kept = if truncated, do: tl(files), else: files
    {Enum.reverse(kept), truncated}
  end

  defp walk_files(_abs, _rel, depth, acc, count)
       when depth > @walk_max_depth or count > @walk_max_files,
       do: {acc, count}

  defp walk_files(abs_dir, rel_dir, depth, acc, count) do
    entries =
      case File.ls(abs_dir) do
        {:ok, names} -> Enum.sort(names)
        {:error, _reason} -> []
      end

    Enum.reduce_while(entries, {acc, count}, fn name, {acc, count} ->
      cond do
        count > @walk_max_files ->
          {:halt, {acc, count}}

        # Names that are not valid UTF-8 cannot round-trip through JSON.
        not String.valid?(name) ->
          {:cont, {acc, count}}

        true ->
          abs = Path.join(abs_dir, name)
          rel = if rel_dir == "", do: name, else: rel_dir <> "/" <> name

          case File.lstat(abs) do
            {:ok, %File.Stat{type: :directory}} ->
              if String.starts_with?(name, ".") or MapSet.member?(@walk_skip_dirs, name) do
                {:cont, {acc, count}}
              else
                {:cont, walk_files(abs, rel, depth + 1, acc, count)}
              end

            {:ok, %File.Stat{type: :regular}} ->
              {:cont, {[rel | acc], count + 1}}

            # Symlinks and specials are skipped: no cycles, no surprises.
            _other ->
              {:cont, {acc, count}}
          end
      end
    end)
  end

  defp expand(path), do: Dala.Paths.expand_user(path)

  defp entry(dir, name) do
    full = Path.join(dir, name)
    symlink? = match?({:ok, %File.Stat{type: :symlink}}, File.lstat(full))

    case File.stat(full, time: :posix) do
      {:ok, %File.Stat{type: type, size: size, mtime: mtime}} ->
        %{
          name: name,
          type: normalize_type(type),
          symlink: symlink?,
          size: size,
          mtime: DateTime.from_unix!(mtime)
        }

      {:error, _reason} ->
        %{name: name, type: "other", symlink: symlink?, size: 0, mtime: nil}
    end
  end

  defp normalize_type(:directory), do: "directory"
  defp normalize_type(:regular), do: "file"
  defp normalize_type(_), do: "other"

  defp read_head(path, max_bytes) do
    File.open(path, [:read, :binary], fn io ->
      case IO.binread(io, max_bytes) do
        data when is_binary(data) -> data
        :eof -> ""
        {:error, reason} -> throw({:read_error, reason})
      end
    end)
  catch
    {:read_error, reason} -> {:error, reason}
  end

  # A multi-byte UTF-8 character can be cut at the truncation boundary, so
  # trimming up to 3 trailing bytes may recover a valid text prefix. Anything
  # still invalid after that (or containing NUL) is not UTF-8 text.
  defp to_text(data) do
    if String.contains?(data, <<0>>) do
      :binary
    else
      case Dala.Utf8.trim_partial_suffix(data) do
        {:ok, prefix} -> {:ok, prefix}
        :error -> :binary
      end
    end
  end
end
