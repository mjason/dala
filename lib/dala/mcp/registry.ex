defmodule Dala.Mcp.Registry do
  @moduledoc """
  Turns the `Dala.Settings` domain's `typescript_rpc` surface into MCP tool
  definitions, so any `rpc_action` added there shows up as a tool automatically
  — no second list to keep in sync.

  Introspection is driven off `AshTypescript.Rpc.Info.typescript_rpc/1`, which
  returns one struct per exposed resource, each carrying its `rpc_actions`
  (`%{name, action, get?, ...}`). For every rpc action we look up the Ash action
  it points at (`Ash.Resource.Info.action/2`), classify it (list / get / create /
  update / destroy / generic), and derive a JSON-Schema `inputSchema` from the
  action's accepted attributes and arguments.

  Two non-Ash theme helpers are appended: `theme_reference` exposes the 46-token
  vocabulary and `preview_theme` provides a deterministic PNG plus audit before
  an agent saves anything. Their execution lives in `Dala.Mcp.Tools`.
  """

  alias Dala.Settings.Theme.Tokens

  @domain Dala.Settings
  @reference_tool_name "theme_reference"
  @preview_tool_name "preview_theme"

  # SECURITY: resources that manage the MCP endpoint ITSELF must never become
  # MCP tools. `Dala.Settings.Mcp` is exposed over `typescript_rpc` for the
  # auth-gated web Settings panel, but if its actions leaked into `tools/list`,
  # an AI talking to `/mcp` could toggle MCP off (locking itself out), read its
  # own bearer token, or rotate it — privilege escalation / a footgun. We filter
  # such resources out here so they can NEVER surface as a callable tool.
  @self_managed_resources [Dala.Settings.Mcp]

  @doc "The name of the non-Ash `theme_reference` helper tool."
  def reference_tool_name, do: @reference_tool_name

  @doc "The name of the headless theme preview helper."
  def preview_tool_name, do: @preview_tool_name

  @doc """
  Internal specs for every auto-derived tool: `%{name, resource, action, kind,
  description, input_schema}`. Used both to render `tools/0` and to build the
  executor's dispatch table in `Dala.Mcp.Tools`.
  """
  def specs do
    for resource_rpc <- AshTypescript.Rpc.Info.typescript_rpc(@domain),
        resource_rpc.resource not in @self_managed_resources,
        rpc_action <- resource_rpc.rpc_actions do
      spec(resource_rpc.resource, rpc_action)
    end
  end

  @doc "The full tool list (JSON-Schema maps) for a `tools/list` response."
  def tools do
    access = Dala.Settings.Mcp.terminal_access()

    Enum.map(specs(), &to_tool/1) ++
      [reference_tool(), preview_tool()] ++
      Dala.Mcp.TerminalTools.tools(access) ++
      Dala.Mcp.FileTools.tools(access)
  end

  @doc "Short server-level guidance returned during MCP initialization."
  def instructions do
    access = Dala.Settings.Mcp.terminal_access()

    theme =
      "For theme design, call theme_reference, iterate with preview_theme, and only then " <>
        "create_theme or update_theme."

    [theme, Dala.Mcp.TerminalTools.instructions(access), Dala.Mcp.FileTools.instructions(access)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp spec(resource, rpc_action) do
    action = Ash.Resource.Info.action(resource, rpc_action.action)
    kind = classify(action)
    name = to_string(rpc_action.name)

    %{
      name: name,
      resource: resource,
      action: rpc_action.action,
      kind: kind,
      description: describe(name, action),
      input_schema: input_schema(resource, action, kind)
    }
  end

  defp to_tool(spec) do
    %{
      "name" => spec.name,
      "description" => spec.description,
      "inputSchema" => spec.input_schema
    }
  end

  # --- classification -------------------------------------------------------

  defp classify(%{type: :read} = action), do: if(action.get?, do: :get, else: :list)
  defp classify(%{type: :create}), do: :create
  defp classify(%{type: :update}), do: :update
  defp classify(%{type: :destroy}), do: :destroy
  defp classify(%{type: :action}), do: :generic

  # --- input schema ---------------------------------------------------------

  defp input_schema(resource, action, kind) do
    {props, required} = collect(resource, action, kind)

    %{
      "type" => "object",
      "properties" => enrich_tokens(props),
      "required" => required
    }
  end

  # Accepted attributes (create/update) + action arguments + a synthetic string
  # `id` for the identity lookup that update/destroy need.
  defp collect(resource, action, kind) do
    accepted = if kind in [:create, :update], do: action.accept, else: []

    attr_props =
      for name <- accepted, into: %{}, do: {to_string(name), attribute_schema(resource, name)}

    arg_props =
      for arg <- action.arguments, into: %{}, do: {to_string(arg.name), argument_schema(arg)}

    {id_props, id_required} =
      if kind in [:update, :destroy] do
        {%{"id" => %{"type" => "string", "description" => "The id of the theme to #{kind}."}},
         ["id"]}
      else
        {%{}, []}
      end

    # Create semantics: a non-nullable, default-less attribute is required.
    # Update semantics: accepted attributes are optional (a partial edit is
    # valid), only the identity `id` is mandatory.
    attr_required =
      if kind == :create do
        for name <- accepted, required_attribute?(resource, name), do: to_string(name)
      else
        []
      end

    arg_required = for arg <- action.arguments, required_argument?(arg), do: to_string(arg.name)

    props = attr_props |> Map.merge(arg_props) |> Map.merge(id_props)
    required = Enum.uniq(attr_required ++ arg_required ++ id_required)
    {props, required}
  end

  defp attribute_schema(resource, name) do
    attribute = Ash.Resource.Info.attribute(resource, name)

    attribute.type
    |> type_schema(attribute.constraints)
    |> maybe_put_description(attribute.description)
  end

  defp argument_schema(argument) do
    argument.type
    |> type_schema(argument.constraints)
    |> maybe_put_description(argument.description)
  end

  defp required_attribute?(resource, name) do
    attribute = Ash.Resource.Info.attribute(resource, name)
    attribute.allow_nil? == false and is_nil(attribute.default)
  end

  defp required_argument?(argument) do
    argument.allow_nil? == false and is_nil(argument.default)
  end

  # Ash type -> JSON Schema fragment.
  defp type_schema(Ash.Type.String, _constraints), do: %{"type" => "string"}
  defp type_schema(Ash.Type.CiString, _constraints), do: %{"type" => "string"}
  defp type_schema(Ash.Type.UUID, _constraints), do: %{"type" => "string"}
  defp type_schema(Ash.Type.Boolean, _constraints), do: %{"type" => "boolean"}
  defp type_schema(Ash.Type.Integer, _constraints), do: %{"type" => "integer"}
  defp type_schema(Ash.Type.Map, _constraints), do: %{"type" => "object"}

  defp type_schema(Ash.Type.Atom, constraints) do
    case Keyword.get(constraints, :one_of) do
      values when is_list(values) ->
        %{"type" => "string", "enum" => Enum.map(values, &to_string/1)}

      _ ->
        %{"type" => "string"}
    end
  end

  # Unknown/unmapped type: permissive (accept anything).
  defp type_schema(_type, _constraints), do: %{}

  defp maybe_put_description(schema, description)
       when is_binary(description) and description != "",
       do: Map.put(schema, "description", description)

  defp maybe_put_description(schema, _description), do: schema

  # The `tokens` property gets the full 46-key contract inlined.
  defp enrich_tokens(%{"tokens" => _} = props) do
    Map.put(props, "tokens", tokens_schema())
  end

  defp enrich_tokens(props), do: props

  # --- descriptions ---------------------------------------------------------

  defp describe("create_theme", _action), do: theme_write_description(:create)
  defp describe("update_theme", _action), do: theme_write_description(:update)
  defp describe(_name, action), do: action.description || ""

  defp theme_write_description(kind) do
    lead =
      case kind do
        :create -> "Create a custom terminal + UI theme in the shared/global dala library."
        :update -> "Edit an existing theme. Pass the theme `id` plus only the fields to change."
      end

    merge_note =
      if kind == :update do
        "On update the `tokens` you pass are MERGED into the theme's existing " <>
          "overrides: omitted slots are kept, so you can change one colour " <>
          "without resending the rest.\n"
      else
        ""
      end

    """
    #{lead}
    `base` is light|dark and picks which built-in palette omitted tokens fall
    back to. `tokens` is a sparse map of CSS colours (hex #rrggbb, rgb()/rgba(),
    or transparent) — include only the slots you override. #{merge_note}Aim for readable
    contrast: body text >= 4.5:1 against its background, UI chrome >= 3.0:1. To
    fork a built-in, call list_themes, copy the preset's tokens, then tweak.
    Call theme_reference for all 46 token keys and the preset ids, then use
    preview_theme until its PNG and audit are ready before create/update.
    """
    |> String.trim()
  end

  defp reference_tool do
    %{
      "name" => @reference_tool_name,
      "description" =>
        "Reference vocabulary for defining themes: the 46 token keys grouped by " <>
          "area, the built-in preset names/ids/bases to fork, and the colour + " <>
          "contrast rules. Follow it with preview_theme before create_theme/update_theme.",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }
  end

  defp preview_tool do
    %{
      "name" => @preview_tool_name,
      "description" =>
        "Render and audit a theme without saving it. Pass either theme_id, or base plus a " <>
          "sparse tokens map. Returns resolved tokens, explicit errors/warnings/suggestions, " <>
          "and a deterministic image/png preview with fictional content only.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "theme_id" => %{"type" => "string"},
          "base" => %{"type" => "string", "enum" => ["light", "dark"]},
          "tokens" => tokens_schema()
        },
        "oneOf" => [
          %{
            "required" => ["theme_id"],
            "not" => %{"anyOf" => [%{"required" => ["base"]}, %{"required" => ["tokens"]}]}
          },
          %{"required" => ["base"], "not" => %{"required" => ["theme_id"]}}
        ]
      }
    }
  end

  defp tokens_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => Map.new(Tokens.token_keys(), &{&1, %{"type" => "string"}}),
      "description" =>
        "sparse map, omit what you don't override; CSS colors only " <>
          "(hex #rrggbb / rgb()/rgba()/hsl()/hsla()); omitted keys inherit the base"
    }
  end
end
