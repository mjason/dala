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
  end

  defp expand("~" <> rest), do: Path.expand((System.user_home() || "/") <> rest)
  defp expand(path), do: Path.expand(path)

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
  # still invalid after that is not UTF-8 text.
  defp to_text(data) do
    if String.contains?(data, <<0>>) do
      :binary
    else
      Enum.find_value(0..3, :binary, fn trim ->
        len = byte_size(data) - trim

        with true <- len >= 0,
             prefix = binary_part(data, 0, len),
             true <- String.valid?(prefix) do
          {:ok, prefix}
        else
          _ -> nil
        end
      end)
    end
  end
end
