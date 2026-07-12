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
  file (basedpyright for Python itself + `dm lsp` for the DSL inside
  `ctx.dsl("...")` strings).

  Candidate paths are checked explicitly (`~/.local/bin`, `~/.cargo/bin`,
  Mason) besides PATH — under systemd the service PATH is minimal, and these
  must be RUNTIME lookups: a release is compiled on CI where $HOME is not the
  user's.
  """

  @doc "Servers for `path` under `root`: `[%{id, name, command}]` in spawn order."
  def servers(root, path) do
    probe(root, path).servers
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
      _ -> nil
    end
  end

  defp describe({command, index}) do
    %{id: index, name: server_name(command), command: command}
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

  defp resolve(language, root) do
    case configured(root)[language] do
      commands when is_list(commands) and commands != [] ->
        commands = Enum.map(commands, &absolutize(&1, root))

        checked =
          for [bin | _] <- commands do
            %{path: bin <> " (dala.jsonc)", found: File.regular?(bin)}
          end

        {Enum.filter(commands, fn [bin | _] -> File.regular?(bin) end), checked}

      _ ->
        discover(language, root)
    end
  end

  # `dala.jsonc` (root-level, "lsp" key, comments ok) or `.dala/lsp.json`
  # (whole file is the language map): { "<language>": [ { "command": [...] } ] }
  defp configured(root) do
    jsonc =
      with {:ok, body} <- File.read(Path.join(root, "dala.jsonc")),
           {:ok, %{"lsp" => %{} = map}} <- Jason.decode(strip_jsonc(body)) do
        map
      else
        _ -> nil
      end

    legacy =
      with {:ok, body} <- File.read(Path.join(root, ".dala/lsp.json")),
           {:ok, %{} = map} <- Jason.decode(body) do
        map
      else
        _ -> nil
      end

    case jsonc || legacy do
      nil ->
        %{}

      map ->
        Map.new(map, fn {language, entries} ->
          commands =
            for %{"command" => [_ | _] = command} <- List.wrap(entries),
                Enum.all?(command, &is_binary/1),
                do: Enum.map(command, &expand_vars(&1, root))

          {language, commands}
        end)
    end
  end

  # //-comments and /* */-comments outside strings, plus trailing commas —
  # enough JSONC for a config file without pulling in a parser dependency.
  defp strip_jsonc(body) do
    body
    |> scan_jsonc([], :code)
    |> IO.iodata_to_binary()
    |> String.replace(~r/,(\s*[}\]])/, "\\1")
  end

  defp scan_jsonc(<<>>, acc, _state), do: Enum.reverse(acc)

  defp scan_jsonc(<<?\\, ?", rest::binary>>, acc, :string),
    do: scan_jsonc(rest, ["\\\"" | acc], :string)

  defp scan_jsonc(<<?", rest::binary>>, acc, :string), do: scan_jsonc(rest, [?" | acc], :code)

  defp scan_jsonc(<<c::utf8, rest::binary>>, acc, :string),
    do: scan_jsonc(rest, [<<c::utf8>> | acc], :string)

  defp scan_jsonc(<<?", rest::binary>>, acc, :code), do: scan_jsonc(rest, [?" | acc], :string)
  defp scan_jsonc(<<"//", rest::binary>>, acc, :code), do: scan_jsonc(rest, acc, :line_comment)
  defp scan_jsonc(<<"/*", rest::binary>>, acc, :code), do: scan_jsonc(rest, acc, :block_comment)

  defp scan_jsonc(<<c::utf8, rest::binary>>, acc, :code),
    do: scan_jsonc(rest, [<<c::utf8>> | acc], :code)

  defp scan_jsonc(<<?\n, rest::binary>>, acc, :line_comment),
    do: scan_jsonc(rest, [?\n | acc], :code)

  defp scan_jsonc(<<_c::utf8, rest::binary>>, acc, :line_comment),
    do: scan_jsonc(rest, acc, :line_comment)

  defp scan_jsonc(<<"*/", rest::binary>>, acc, :block_comment), do: scan_jsonc(rest, acc, :code)

  defp scan_jsonc(<<_c::utf8, rest::binary>>, acc, :block_comment),
    do: scan_jsonc(rest, acc, :block_comment)

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
  defp home(rel), do: Path.join(System.user_home() || "/", rel)
  defp mason_bin(name), do: home(".local/share/nvim/mason/bin/#{name}")
  defp local_bin(name), do: home(".local/bin/#{name}")

  defp discover("python", root) do
    {pyright, checked_pyright} =
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

    # dark-magician workspaces (marked by dmagic.py) ship a DSL server that
    # rides alongside pyright on the same .py files.
    {dm, checked_dm} =
      if File.regular?(Path.join(root, "dmagic.py")) do
        first_existing([{Path.join(root, ".venv/bin/dm"), ["lsp"]}])
      else
        {[], []}
      end

    {pyright ++ dm, checked_pyright ++ checked_dm}
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
          [[bin | args]]
      end

    {commands, checked}
  end
end
