defmodule Dala.Mcp.Tools do
  @moduledoc """
  Executes an MCP tool call against the `Dala.Settings` domain.

  Every action runs with `actor: nil` and `authorize?: false`, exactly the way
  `AshTypescript.Rpc` runs them: the resources are `authorize? false` and do
  their isolation with manual scope filters, so a nil actor means the
  shared/global settings library. AI-defined themes therefore land in the
  global library and are visible on every device — matching the domain's
  "auth off = shared `user_id nil` row" design. The built-in write guards
  (colour whitelist, built-in/owner checks) still fire as ordinary validations.

  Results are sanitised before they leave the server: a `:map`-returning action
  is passed through (minus nils); a struct is reduced to its PUBLIC,
  NON-`sensitive?` attributes. An API key or any other sensitive attribute can
  never appear in a result.
  """

  alias Dala.Mcp.Registry
  alias Dala.Settings.Theme.{Palette, Presets, Tokens}

  @theme_token_descriptions %{
    "bg0" => "Primary app and editor background.",
    "bg1" => "Secondary surfaces such as sidebars, panels and the composer.",
    "bg2" => "Raised, selected and hover surfaces.",
    "line" => "Borders, dividers and subtle outlines.",
    "fg" => "Primary UI and editor text.",
    "fgMuted" => "Secondary labels, metadata and placeholders.",
    "mint" => "Primary action, focus and active-state accent.",
    "danger" => "Destructive actions and error emphasis.",
    "gitAdded" => "Git added-file labels and names.",
    "gitModified" => "Git modified-file labels, names and commit hashes.",
    "gitDeleted" => "Git deleted-file labels and names.",
    "gitRenamed" => "Git renamed/copied-file labels and names.",
    "gitUntracked" => "Git untracked-file labels and names.",
    "gitConflict" => "Git merge-conflict labels and names.",
    "gitIgnored" => "Subtle labels and names for files excluded by Git ignore rules.",
    "diffAddFg" => "Added-line marker and text emphasis.",
    "diffDelFg" => "Deleted-line marker and text emphasis.",
    "diffHunk" => "Diff hunk headers and location markers.",
    "diffAddBg" => "Added-line background tint.",
    "diffDelBg" => "Deleted-line background tint.",
    "cmGutterBg" => "CodeMirror gutter background.",
    "cmGutterFg" => "CodeMirror line numbers and gutter text.",
    "cmActiveBg" => "CodeMirror active-line background.",
    "cmHunkBg" => "CodeMirror changed-hunk background.",
    "cmSelection" => "CodeMirror selection background.",
    "termBackground" => "Terminal canvas background.",
    "termForeground" => "Terminal default text.",
    "termCursor" => "Terminal cursor colour.",
    "termCursorAccent" => "Glyph colour underneath a block cursor.",
    "termSelectionBackground" => "Terminal selection background."
  }

  @doc """
  Run the named tool. Returns `{:ok, clean_result}` (result may be `nil` for a
  `get` miss), `{:error, message}` for a validation/execution failure, or
  `{:error, :unknown_tool}` when no tool has that name.
  """
  def call(name, arguments) when is_binary(name) do
    cond do
      name in Dala.Mcp.TerminalTools.tool_names() ->
        Dala.Mcp.TerminalTools.call(name, arguments)

      name == Registry.reference_tool_name() ->
        {:ok, reference()}

      name == Registry.preview_tool_name() ->
        case Dala.Settings.Theme.Preview.run(normalize(arguments)) do
          {:ok, report, png} -> {:ok, {:mcp_content, report, png}}
          {:error, message} -> {:error, message}
        end

      true ->
        case Map.fetch(index(), name) do
          {:ok, spec} -> execute(spec, normalize(arguments))
          :error -> {:error, :unknown_tool}
        end
    end
  end

  def call(_name, _arguments), do: {:error, :unknown_tool}

  defp index, do: Map.new(Registry.specs(), &{&1.name, &1})

  defp normalize(arguments) when is_map(arguments), do: arguments
  defp normalize(_arguments), do: %{}

  defp execute(%{resource: resource, action: action, kind: kind}, arguments) do
    run(kind, resource, action, arguments)
  rescue
    error -> {:error, error_message(error)}
  end

  # --- dispatch by kind -----------------------------------------------------

  defp run(:list, resource, action, arguments) do
    resource
    |> Ash.Query.for_read(action, arguments, actor: nil)
    |> Ash.read(authorize?: false)
    |> format(:list, resource)
  end

  defp run(:get, resource, action, arguments) do
    resource
    |> Ash.Query.for_read(action, arguments, actor: nil)
    |> Ash.read_one(authorize?: false)
    |> format(:get, resource)
  end

  defp run(:generic, resource, action, arguments) do
    resource
    |> Ash.ActionInput.for_action(action, arguments, actor: nil)
    |> Ash.run_action(authorize?: false)
    |> format(:generic, resource)
  end

  defp run(:create, resource, action, arguments) do
    resource
    |> Ash.Changeset.for_create(action, arguments, actor: nil)
    |> Ash.create(authorize?: false)
    |> format(:create, resource)
  end

  defp run(:update, resource, action, arguments) do
    with {:ok, record} <- fetch(resource, arguments) do
      attrs = arguments |> Map.delete("id") |> merge_tokens(record)

      record
      |> Ash.Changeset.for_update(action, attrs, actor: nil)
      |> Ash.update(authorize?: false)
      |> format(:update, resource)
    end
  end

  defp run(:destroy, resource, action, arguments) do
    with {:ok, record} <- fetch(resource, arguments) do
      record
      |> Ash.Changeset.for_destroy(action, Map.delete(arguments, "id"), actor: nil)
      |> Ash.destroy(authorize?: false, return_destroyed?: true)
      |> format(:destroy, resource)
    end
  end

  # An MCP update is a SPARSE edit: the tokens the agent sends are MERGED into
  # the theme's stored overrides (add/change slots), never a wholesale replace —
  # otherwise a single-token tweak would silently wipe every other override,
  # which the tool's own "omit what you don't override" wording invites. Only
  # the theme resource carries a `tokens` map; other updates pass through.
  # (The web editor sends the full map and uses the same action unchanged.)
  defp merge_tokens(%{"tokens" => incoming} = attrs, record) when is_map(incoming) do
    existing = Map.get(record, :tokens) || %{}
    %{attrs | "tokens" => Map.merge(existing, incoming)}
  end

  defp merge_tokens(attrs, _record), do: attrs

  # Update/destroy fetch their target scoped to the global actor first; the
  # resource's own write guards then enforce built-in/owner rules.
  defp fetch(resource, arguments) do
    case Map.get(arguments, "id") || Map.get(arguments, :id) do
      id when is_binary(id) and id != "" ->
        case Ash.get(resource, id, actor: nil, authorize?: false) do
          {:ok, record} -> {:ok, record}
          {:error, error} -> {:error, error_message(error)}
        end

      _ ->
        {:error, "id is required"}
    end
  end

  # --- result shaping -------------------------------------------------------

  defp format({:ok, value}, kind, resource), do: {:ok, clean(value, kind, resource)}
  defp format(:ok, _kind, _resource), do: {:ok, %{"ok" => true}}
  defp format({:error, error}, _kind, _resource), do: {:error, error_message(error)}

  defp clean(nil, _kind, _resource), do: nil

  defp clean(list, :list, resource) when is_list(list),
    do: Enum.map(list, &clean_struct(resource, &1))

  defp clean(value, :generic, _resource) when is_map(value), do: clean_map(value)
  defp clean(value, _kind, resource) when is_struct(value), do: clean_struct(resource, value)
  defp clean(value, _kind, _resource), do: value

  # Public, non-sensitive attributes only — sensitive attrs (e.g. api_key) are
  # dropped so they can never be serialised into a tool result.
  defp clean_struct(resource, record) do
    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.reject(& &1.sensitive?)
    |> Map.new(fn attribute -> {attribute.name, Map.get(record, attribute.name)} end)
  end

  defp clean_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # --- error extraction (never leaks a stacktrace) --------------------------

  defp error_message(message) when is_binary(message), do: message

  defp error_message(error) do
    error
    |> leaf_errors()
    |> Enum.map(&leaf_message/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "request failed"
      messages -> messages |> Enum.uniq() |> Enum.join("; ")
    end
  end

  defp leaf_errors(error) when is_struct(error) do
    Ash.Error.to_error_class(error).errors
  rescue
    _ -> [error]
  end

  defp leaf_errors(error), do: [error]

  # `Exception.message/1` on an Ash leaf splices in "Bread Crumbs" and file:line
  # frames, so read the plain `.message` field and only humanise the struct name
  # as a last resort.
  defp leaf_message(leaf) do
    case leaf do
      %{message: message} when is_binary(message) and message != "" -> message
      %{__struct__: struct} -> struct |> Module.split() |> List.last() |> humanize()
      _ -> nil
    end
  end

  defp humanize(name) do
    name
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.downcase()
  end

  # --- theme_reference payload ----------------------------------------------

  defp reference do
    keys = Tokens.token_keys()
    {ui, rest} = Enum.split(keys, 8)
    {git, rest} = Enum.split(rest, 7)
    {diff, rest} = Enum.split(rest, 5)
    {codemirror, rest} = Enum.split(rest, 5)
    {terminal, ansi} = Enum.split(rest, 5)

    groups = %{
      "ui" => ui,
      "git" => git,
      "diff" => diff,
      "codemirror" => codemirror,
      "terminal" => terminal,
      "ansi" => ansi
    }

    dark = Palette.base_tokens(:dark)
    light = Palette.base_tokens(:light)

    %{
      "tokenCount" => Tokens.count(),
      "tokenKeys" => groups,
      "tokenDefinitions" => token_definitions(groups, dark, light),
      "bases" => ["light", "dark"],
      "supportedOperations" => [
        %{"tool" => "list_themes", "effect" => "read visible built-in and custom themes"},
        %{"tool" => "get_theme", "effect" => "read one theme and its sparse overrides"},
        %{"tool" => "preview_theme", "effect" => "resolve, audit and render without saving"},
        %{"tool" => "create_theme", "effect" => "save a new shared custom theme"},
        %{"tool" => "update_theme", "effect" => "merge sparse changes into a custom theme"},
        %{"tool" => "delete_theme", "effect" => "delete a custom theme; built-ins are protected"}
      ],
      "presets" =>
        Enum.map(Presets.all(), fn preset ->
          %{"id" => preset.id, "name" => preset.name, "base" => to_string(preset.base)}
        end),
      "previewWorkflow" => [
        "theme_reference",
        "preview_theme",
        "adjust tokens from the PNG and audit",
        "preview_theme again",
        "create_theme or update_theme"
      ],
      "reviewRules" => %{
        "hard" => [
          "body and important text contrast",
          "primary and danger button text contrast",
          "Git states against file/Git panel backgrounds",
          "diff added/deleted text against row backgrounds"
        ],
        "warnings" => [
          "three backgrounds are difficult to distinguish",
          "primary accent is reused too broadly",
          "Git status colours are too similar",
          "many ANSI colours disappear into the terminal background",
          "semantic palette is concentrated in one hue family"
        ],
        "scoring" => "No single beauty score; hard failures and heuristic warnings stay separate."
      },
      "colorRules" =>
        "Token values must be plain CSS colours: hex (#rgb / #rrggbb / #rrggbbaa), " <>
          "rgb()/rgba()/hsl()/hsla(), or the keyword transparent; max 64 chars. " <>
          "url()/image-set()/expressions are rejected on write. Omit a token to " <>
          "inherit the base palette. Aim for readable contrast: body text >= 4.5:1 " <>
          "against its background, UI chrome >= 3.0:1."
    }
  end

  defp token_definitions(groups, dark, light) do
    for {group, keys} <- groups, key <- keys, into: %{} do
      {key,
       %{
         "group" => group,
         "description" => token_description(key),
         "defaults" => %{"dark" => dark[key], "light" => light[key]}
       }}
    end
  end

  defp token_description("ansiBright" <> colour),
    do: "Bright ANSI #{String.downcase(colour)} used by terminal programs."

  defp token_description("ansi" <> colour),
    do: "ANSI #{String.downcase(colour)} used by terminal programs."

  defp token_description(key), do: Map.fetch!(@theme_token_descriptions, key)
end
