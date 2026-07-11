defmodule Dala.Lsp.Discovery do
  @moduledoc """
  Resolves which language servers should attach to a file, per project root.

  Project-local installs win: a Python venv's basedpyright knows the project's
  interpreter and reads its `[tool.pyright]` config, which a global install
  might miss. A `.dala/lsp.json` at the root overrides discovery entirely for
  the languages it lists:

      { "python": [ { "command": [".venv/bin/basedpyright-langserver", "--stdio"] },
                    { "command": [".venv/bin/dm", "lsp"] } ] }

  Relative commands resolve against the root. Several servers may attach to
  one file (basedpyright for Python itself + `dm lsp` for the DSL inside
  `ctx.dsl("...")` strings).
  """

  @mason_bin Path.join([System.user_home() || "/", ".local/share/nvim/mason/bin"])

  @doc "Servers for `path` under `root`: `[%{id, name, command}]` in spawn order."
  def servers(root, path) do
    case language_of(path) do
      nil -> []
      language -> language |> resolve(root) |> Enum.with_index() |> Enum.map(&describe/1)
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
        Enum.map(commands, &absolutize(&1, root))

      _ ->
        discover(language, root)
    end
  end

  # `.dala/lsp.json`: { "<language>": [ { "command": [...] } ] }
  defp configured(root) do
    with {:ok, body} <- File.read(Path.join(root, ".dala/lsp.json")),
         {:ok, %{} = map} <- Jason.decode(body) do
      Map.new(map, fn {language, entries} ->
        commands =
          for %{"command" => [_ | _] = command} <- List.wrap(entries),
              Enum.all?(command, &is_binary/1),
              do: command

        {language, commands}
      end)
    else
      _ -> %{}
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

  defp discover("python", root) do
    pyright =
      first_existing([
        {Path.join(root, ".venv/bin/basedpyright-langserver"), ["--stdio"]},
        {Path.join(root, ".venv/bin/pyright-langserver"), ["--stdio"]},
        {System.find_executable("basedpyright-langserver"), ["--stdio"]},
        {System.find_executable("pyright-langserver"), ["--stdio"]},
        {Path.join(@mason_bin, "pyright-langserver"), ["--stdio"]}
      ])

    # dark-magician workspaces (marked by dmagic.py) ship a DSL server that
    # rides alongside pyright on the same .py files.
    dm =
      if File.regular?(Path.join(root, "dmagic.py")) do
        first_existing([{Path.join(root, ".venv/bin/dm"), ["lsp"]}])
      else
        []
      end

    pyright ++ dm
  end

  defp discover("rust", _root) do
    first_existing([
      {System.find_executable("rust-analyzer"), []},
      {Path.join([System.user_home() || "/", ".cargo/bin/rust-analyzer"]), []}
    ])
  end

  defp discover("elixir", _root) do
    first_existing([
      {System.find_executable("elixir-ls"), []},
      {Path.join(@mason_bin, "elixir-ls"), []}
    ])
  end

  defp discover("lua", _root) do
    first_existing([
      {System.find_executable("lua-language-server"), []},
      {Path.join(@mason_bin, "lua-language-server"), []}
    ])
  end

  defp discover(_language, _root), do: []

  # The first candidate whose binary exists, as a one-element list of commands.
  defp first_existing(candidates) do
    Enum.find_value(candidates, [], fn
      {nil, _args} -> nil
      {bin, args} -> if File.regular?(bin), do: [[bin | args]]
    end)
  end
end
