defmodule Dala.Lsp.Discovery do
  @moduledoc """
  Resolves which language servers should attach to a file, per project root.

  Project-local installs win: a Python venv's basedpyright knows the project's
  interpreter and reads its `[tool.pyright]` config, which a global install
  might miss. A `.dala/lsp.json` at the root overrides discovery entirely for
  the languages it lists:

      { "python": [ { "command": [".venv/bin/basedpyright-langserver", "--stdio"] },
                    { "command": [".venv/bin/dm", "lsp"] } ] }

  A root-level `dala.jsonc` works too (comments allowed) under an `lsp` key:

      {
        // project-wide dala config
        "lsp": { "python": [ { "command": ["$HOME/tools/my-lsp", "--stdio"] } ] }
      }

  Command words expand `~`, `$VAR`/`${VAR}` and `${root}` (the project root);
  relative paths resolve against the root. Several servers may attach to one
  file — e.g. basedpyright for Python itself plus a framework's own DSL
  server declared in dala.jsonc. Discovery itself only knows UNIVERSAL
  conventions (venvs, PATH, ~/.local/bin, mason); anything framework-specific
  belongs in the project's dala.jsonc.

  Candidate paths are checked explicitly (`~/.local/bin`, `~/.cargo/bin`,
  Mason) besides PATH — under systemd the service PATH is minimal, and these
  must be RUNTIME lookups: a release is compiled on CI where $HOME is not the
  user's.

  `.dala/lsp.json` (whole file = the language map) is the legacy config
  location and is still honored, though `dala.jsonc` wins when both exist.
  """

  @doc "Servers for `path` under `root`: `[%{id, name, command}]` in spawn order."
  def servers(root, path) do
    probe(root, path).servers
  end

  @doc """
  Full resolution from an absolute file path: the effective project root and
  the servers. Monorepos work two ways — a nested `dala.jsonc` in the
  sub-project (nearest one wins), or the top config's `"projects"` map:

      { "lsp": { "elixir": [...] },
        "projects": { "assets": { "lsp": { "typescript": [...] } } } }

  A file under `assets/` then resolves with root (LSP rootUri + cwd) at
  `<config dir>/assets`.
  """
  def probe_file(path) do
    dir = Path.dirname(path)

    case nearest_config_dir(dir) do
      nil ->
        root = Dala.Paths.git_toplevel(dir) || dir
        Map.put(probe(root, path), :root, root)

      config_dir ->
        {root, scoped} = scope_for(config_dir, path)
        Map.put(probe_scoped(root, path, scoped), :root, root)
    end
  end

  @doc """
  Like `servers/2`, plus the probe trace: every candidate checked and whether
  it exists — the debug window's answer to "why didn't my LSP start".
  """
  def probe(root, path) do
    case language_of(path) do
      nil ->
        %{language: nil, servers: [], checked: []}

      language ->
        {commands, checked} = resolve(language, root)

        %{
          language: language,
          servers: commands |> Enum.with_index() |> Enum.map(&describe/1),
          checked: checked
        }
    end
  end

  @doc "The language id used in LSP `textDocument/didOpen` for this file."
  def language_of(path) do
    case path |> Path.extname() |> String.downcase() do
      ".py" -> "python"
      ".pyi" -> "python"
      ".rs" -> "rust"
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".heex" -> "elixir"
      ".lua" -> "lua"
      ".ts" -> "typescript"
      ".tsx" -> "typescript"
      ".mts" -> "typescript"
      ".cts" -> "typescript"
      ".js" -> "javascript"
      ".jsx" -> "javascript"
      ".mjs" -> "javascript"
      ".cjs" -> "javascript"
      ".go" -> "go"
      _ -> nil
    end
  end

  defp describe({%{command: command} = spec, index}) do
    %{
      id: index,
      name: server_name(command),
      command: command,
      initialization_options: spec[:initialization_options],
      settings: spec[:settings]
    }
  end

  # ".venv/bin/basedpyright-langserver --stdio" → "basedpyright"; "dm lsp" → "dm lsp"
  defp server_name([bin | args]) do
    base = Path.basename(bin)

    case {base, args} do
      {"dm", ["lsp" | _]} -> "dm lsp"
      {"dmi", ["lsp" | _]} -> "dm lsp"
      _ -> String.replace_suffix(base, "-langserver", "")
    end
  end

  # Walk up from the file's directory to the nearest dala.jsonc /
  # .dala/lsp.json, stopping at the git toplevel (inclusive) or $HOME.
  defp nearest_config_dir(dir) do
    Dala.Paths.walk_up(dir, fn current ->
      if File.regular?(Path.join(current, "dala.jsonc")) or
           File.regular?(Path.join(current, ".dala/lsp.json")),
         do: current
    end)
  end

  # The `"projects"` map scopes files to sub-projects: the LONGEST relative
  # path prefix that contains the file wins, and becomes the root.
  defp scope_for(config_dir, path) do
    projects =
      case read_config(config_dir) do
        %{"projects" => %{} = map} -> map
        _ -> %{}
      end

    relative = Path.relative_to(path, config_dir)

    match =
      projects
      |> Map.keys()
      |> Enum.filter(fn sub ->
        sub != "" and String.starts_with?(relative, String.trim_trailing(sub, "/") <> "/")
      end)
      |> Enum.max_by(&String.length/1, fn -> nil end)

    case match do
      nil ->
        {config_dir, nil}

      sub ->
        sub_dir = Path.join(config_dir, sub)

        lsp =
          case projects[sub] do
            %{"lsp" => %{} = map} -> normalize_lsp(map, sub_dir)
            _ -> %{}
          end

        {sub_dir, lsp}
    end
  end

  # Like probe/2 but with an already-scoped config (a "projects" entry).
  # An empty scoped map falls back to universal discovery at the sub-root.
  defp probe_scoped(root, path, nil), do: probe(root, path)

  defp probe_scoped(root, path, scoped) do
    case language_of(path) do
      nil ->
        %{language: nil, servers: [], checked: []}

      language ->
        {commands, checked} =
          case scoped[language] do
            commands when is_list(commands) and commands != [] ->
              check_configured(commands, root)

            _ ->
              discover(language, root)
          end

        %{
          language: language,
          servers: commands |> Enum.with_index() |> Enum.map(&describe/1),
          checked: checked
        }
    end
  end

  defp check_configured(specs, root) do
    specs = Enum.map(specs, fn spec -> %{spec | command: absolutize(spec.command, root)} end)

    checked =
      for %{command: [bin | _]} <- specs do
        %{path: bin <> " (dala.jsonc)", found: File.regular?(bin)}
      end

    {Enum.filter(specs, fn %{command: [bin | _]} -> File.regular?(bin) end), checked}
  end

  defp resolve(language, root) do
    case configured(root)[language] do
      commands when is_list(commands) and commands != [] ->
        check_configured(commands, root)

      _ ->
        discover(language, root)
    end
  end

  # `dala.jsonc` (root-level, "lsp" key, comments ok) or `.dala/lsp.json`
  # (whole file is the language map): { "<language>": [ { "command": [...] } ] }
  defp configured(root) do
    case read_config(root) do
      %{"lsp" => %{} = map} -> normalize_lsp(map, root)
      %{"__legacy__" => %{} = map} -> normalize_lsp(map, root)
      _ -> %{}
    end
  end

  # Raw parsed config for a directory: dala.jsonc wins over .dala/lsp.json
  # (which is wrapped as __legacy__ since its whole body is the lsp map).
  defp read_config(dir) do
    jsonc =
      with {:ok, body} <- File.read(Path.join(dir, "dala.jsonc")),
           {:ok, %{} = map} <- Jason.decode(Dala.Jsonc.strip(body)) do
        map
      else
        _ -> nil
      end

    legacy =
      with {:ok, body} <- File.read(Path.join(dir, ".dala/lsp.json")),
           {:ok, %{} = map} <- Jason.decode(body) do
        %{"__legacy__" => map}
      else
        _ -> nil
      end

    jsonc || legacy || %{}
  end

  defp normalize_lsp(map, root) do
    Map.new(map, fn {language, entries} ->
      specs =
        for %{"command" => [_ | _] = command} = entry <- List.wrap(entries),
            Enum.all?(command, &is_binary/1) do
          %{
            command: Enum.map(command, &expand_vars(&1, root)),
            initialization_options: expand_deep(entry["initializationOptions"], root),
            settings: expand_deep(entry["settings"], root)
          }
        end

      {language, specs}
    end)
  end

  # Variable expansion through nested option maps, so things like
  # {"python": {"pythonPath": "${root}/.venv/bin/python"}} work.
  defp expand_deep(nil, _root), do: nil
  defp expand_deep(value, root) when is_binary(value), do: expand_vars(value, root)
  defp expand_deep(value, root) when is_list(value), do: Enum.map(value, &expand_deep(&1, root))

  defp expand_deep(value, root) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, expand_deep(v, root)} end)

  defp expand_deep(value, _root), do: value

  # `~` and env vars in configured commands: "$HOME/x", "${HOME}/x",
  # "${root}/tools/lsp", "~/bin/lsp".
  defp expand_vars(word, root) do
    word =
      word
      |> String.replace("${root}", root)
      |> then(fn w ->
        Regex.replace(~r/\$\{(\w+)\}|\$(\w+)/, w, fn _, braced, bare ->
          System.get_env(if(braced != "", do: braced, else: bare)) || ""
        end)
      end)

    case word do
      "~/" <> rest -> Path.join(System.user_home() || "/", rest)
      "~" -> System.user_home() || "~"
      other -> other
    end
  end

  defp absolutize([bin | args], root) do
    resolved =
      cond do
        Path.type(bin) == :absolute -> bin
        String.contains?(bin, "/") -> Path.expand(bin, root)
        true -> System.find_executable(bin) || bin
      end

    [resolved | args]
  end

  # Runtime, not compile time: releases are built on CI under a foreign $HOME.
  defp home(rel), do: Dala.Paths.home(rel)
  defp mason_bin(name), do: home(".local/share/nvim/mason/bin/#{name}")
  defp local_bin(name), do: home(".local/bin/#{name}")

  defp discover("python", root) do
    first_existing([
      {Path.join(root, ".venv/bin/basedpyright-langserver"), ["--stdio"]},
      {Path.join(root, ".venv/bin/pyright-langserver"), ["--stdio"]},
      {System.find_executable("basedpyright-langserver"), ["--stdio"]},
      {System.find_executable("pyright-langserver"), ["--stdio"]},
      {local_bin("basedpyright-langserver"), ["--stdio"]},
      {local_bin("pyright-langserver"), ["--stdio"]},
      {mason_bin("basedpyright-langserver"), ["--stdio"]},
      {mason_bin("pyright-langserver"), ["--stdio"]}
    ])
  end

  defp discover("rust", _root) do
    first_existing([
      {System.find_executable("rust-analyzer"), []},
      {home(".cargo/bin/rust-analyzer"), []},
      {local_bin("rust-analyzer"), []}
    ])
  end

  defp discover("elixir", _root) do
    first_existing([
      {System.find_executable("elixir-ls"), []},
      {local_bin("elixir-ls"), []},
      {home(".local/elixir-ls/language_server.sh"), []},
      {mason_bin("elixir-ls"), []}
    ])
  end

  defp discover("lua", _root) do
    first_existing([
      {System.find_executable("lua-language-server"), []},
      {local_bin("lua-language-server"), []},
      {mason_bin("lua-language-server"), []}
    ])
  end

  defp discover(language, _root) when language in ["typescript", "javascript"] do
    first_existing([
      {System.find_executable("typescript-language-server"), ["--stdio"]},
      {local_bin("typescript-language-server"), ["--stdio"]},
      {mason_bin("typescript-language-server"), ["--stdio"]}
    ])
  end

  defp discover("go", _root) do
    first_existing([
      {System.find_executable("gopls"), []},
      {home("go/bin/gopls"), []},
      {local_bin("gopls"), []},
      {mason_bin("gopls"), []}
    ])
  end

  defp discover(_language, _root), do: {[], []}

  # First candidate whose binary exists wins; every probe is recorded so the
  # debug window can show what was looked at and what was missing.
  defp first_existing(candidates) do
    checked =
      candidates
      |> Enum.reject(fn {bin, _args} -> is_nil(bin) end)
      |> Enum.uniq_by(fn {bin, _args} -> bin end)
      |> Enum.map(fn {bin, _args} -> %{path: bin, found: File.regular?(bin)} end)

    commands =
      case Enum.find(checked, & &1.found) do
        nil ->
          []

        %{path: bin} ->
          {_bin, args} = Enum.find(candidates, fn {b, _} -> b == bin end)
          [%{command: [bin | args], initialization_options: nil, settings: nil}]
      end

    {commands, checked}
  end
end
