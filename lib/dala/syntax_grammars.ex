defmodule Dala.SyntaxGrammars do
  @moduledoc """
  TextMate grammar registry for the code editor, two layers deep:

    * **global** — `.tmLanguage.json` files uploaded into
      `<data_dir>/grammars/` (managed from the settings UI); apply everywhere.
    * **project** — `"grammars"` entries in the nearest `dala.jsonc`
      (user-config-first, like the LSP setup): local paths that never leave
      the machine, so private grammars stay private.

  Only metadata is resolved here (scope name, display name, extension
  mapping); clients fetch grammar bodies through the raw file endpoint.
  Project entries come first so they win extension collisions.

  dala.jsonc shape:

      {
        "grammars": [
          {
            "path": "./vscode-extension/syntaxes/magicpython.tmLanguage.json",
            "extensions": [".py"]   // optional; defaults to the grammar's fileTypes
          }
        ]
      }
  """

  @doc "Directory holding globally-uploaded grammars (created on demand)."
  def global_dir do
    :dala
    |> Application.fetch_env!(:data_dir)
    |> Path.expand()
    |> Path.join("grammars")
  end

  @doc """
  Grammars applying to `file_path` (or only the global set when nil):
  project entries first, then global uploads.
  """
  def resolve(file_path) do
    project =
      case file_path do
        nil -> []
        path -> path |> Dala.Paths.expand_user() |> Path.dirname() |> project_grammars()
      end

    %{global_dir: global_dir(), grammars: project ++ global_grammars()}
  end

  defp global_grammars do
    dir = global_dir()
    File.mkdir_p(dir)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            String.ends_with?(name, ".json"),
            meta = grammar_meta(Path.join(dir, name)),
            do: Map.put(meta, :source, "global")

      {:error, _reason} ->
        []
    end
  end

  defp project_grammars(dir) do
    with config when is_binary(config) <- config_file(dir),
         {:ok, body} <- File.read(config),
         {:ok, %{"grammars" => entries}} when is_list(entries) <-
           Jason.decode(Dala.Jsonc.strip(body)) do
      base = Path.dirname(config)

      for %{"path" => path} = entry <- entries,
          is_binary(path),
          meta = grammar_meta(resolve_path(base, path)) do
        extensions =
          case normalize_extensions(entry["extensions"]) do
            [] -> meta.extensions
            explicit -> explicit
          end

        meta
        |> Map.put(:extensions, extensions)
        |> Map.put(:source, "project")
      end
    else
      _no_config_or_no_grammars -> []
    end
  end

  # Reads just enough of a TextMate grammar to route files to it. A file
  # that is missing, unparsable or has no scopeName is silently skipped —
  # a broken grammar must not take the editor down.
  defp grammar_meta(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body),
         scope when is_binary(scope) <- json["scopeName"] do
      %{
        path: path,
        scope_name: scope,
        name: display_name(json, path),
        extensions: normalize_extensions(json["fileTypes"])
      }
    else
      _unusable -> nil
    end
  end

  defp display_name(json, path) do
    case json["name"] do
      name when is_binary(name) and name != "" -> name
      _missing -> Path.basename(path)
    end
  end

  # ["py", ".pyi"] -> [".py", ".pyi"]
  defp normalize_extensions(list) do
    for ext <- List.wrap(list), is_binary(ext), ext != "" do
      if String.starts_with?(ext, "."), do: ext, else: "." <> ext
    end
  end

  defp resolve_path(base, path) do
    cond do
      String.starts_with?(path, "~") -> Dala.Paths.expand_user(path)
      Path.type(path) == :absolute -> Path.expand(path)
      true -> Path.expand(path, base)
    end
  end

  defp config_file(dir) do
    Dala.Paths.walk_up(dir, fn current ->
      path = Path.join(current, "dala.jsonc")
      if File.regular?(path), do: path
    end)
  end
end
