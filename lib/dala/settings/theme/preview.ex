defmodule Dala.Settings.Theme.Preview do
  @moduledoc """
  Headless theme preview pipeline: resolve, audit, draw a fixed SVG scene and
  render it to PNG. It never reads browser state, files or terminal output.
  """

  alias Dala.Settings.Theme
  alias Dala.Settings.Theme.{Audit, Palette, Svg}

  @doc "Build an unsaved preview from `{base, tokens}` or a visible `theme_id`."
  def run(arguments) when is_map(arguments) do
    with {:ok, base, overrides, source} <- input(arguments),
         {:ok, tokens} <- Palette.resolve(base, overrides),
         :ok <- Audit.validate_colors(tokens),
         svg = Svg.render(tokens),
         {:ok, png} <- Dala.ThemeRenderer.render_png(svg, Svg.width(), Svg.height()) do
      report = %{
        schema_version: 1,
        saved: false,
        source: source,
        base: to_string(base),
        tokens: tokens,
        audit: Audit.run(tokens),
        preview: %{
          width: Svg.width(),
          height: Svg.height(),
          mime_type: "image/png",
          renderer: "resvg/tiny-skia",
          scene: "dala-standard-v1",
          contains_user_content: false
        }
      }

      {:ok, report, png}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "theme preview rendering failed: #{inspect(reason)}"}
    end
  end

  def run(_arguments), do: {:error, "preview_theme arguments must be an object"}

  defp input(arguments) do
    theme_id = get(arguments, "theme_id")
    base = get(arguments, "base")
    tokens_present? = has_key?(arguments, "tokens")
    tokens = get(arguments, "tokens") || %{}

    cond do
      present?(theme_id) and (present?(base) or tokens_present?) ->
        {:error, "pass either theme_id or base/tokens, not both"}

      present?(theme_id) ->
        load_theme(theme_id)

      not present?(base) ->
        {:error, "base is required when theme_id is not provided"}

      not is_map(tokens) ->
        {:error, "tokens must be an object"}

      true ->
        case normalize_base(base) do
          {:ok, normalized} -> {:ok, normalized, tokens, %{type: "inline"}}
          {:error, message} -> {:error, message}
        end
    end
  end

  defp load_theme(theme_id) when is_binary(theme_id) do
    result =
      Theme
      |> Ash.Query.for_read(:get, %{id: theme_id}, actor: nil)
      |> Ash.read_one(authorize?: false)

    case result do
      {:ok, %Theme{} = theme} ->
        {:ok, theme.base, theme.tokens || %{}, %{type: "theme_id", theme_id: theme.id}}

      {:ok, nil} ->
        {:error, "theme not found or not visible: #{theme_id}"}

      {:error, _reason} ->
        {:error, "invalid theme_id: #{theme_id}"}
    end
  end

  defp load_theme(_theme_id), do: {:error, "theme_id must be a string"}

  defp normalize_base(base) when base in [:light, "light"], do: {:ok, :light}
  defp normalize_base(base) when base in [:dark, "dark"], do: {:ok, :dark}
  defp normalize_base(_base), do: {:error, "base must be light or dark"}

  defp get(map, key), do: Map.get(map, key, Map.get(map, String.to_existing_atom(key)))

  defp has_key?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, String.to_existing_atom(key))

  defp present?(value), do: not is_nil(value) and value != ""
end
