defmodule Dala.Settings.Theme.Palette do
  @moduledoc """
  Canonical complete light/dark palettes used by headless theme previews.

  The browser keeps the same values in `themeBaseTokens.ts`. Custom themes are
  sparse maps; resolving one is a straight overlay on one of these bases.
  """

  alias Dala.Settings.Theme.Tokens

  @dark %{
    "bg0" => "#0b0c0e",
    "bg1" => "#121417",
    "bg2" => "#1b1e23",
    "line" => "#24272c",
    "fg" => "#e6e8eb",
    "fgMuted" => "#8f96a0",
    "mint" => "#4cc38a",
    "danger" => "#f0716e",
    "gitAdded" => "#5fbf87",
    "gitModified" => "#d9a860",
    "gitDeleted" => "#b4a7ad",
    "gitRenamed" => "#6d9fd6",
    "gitUntracked" => "#7fd0d0",
    "gitConflict" => "#c9a5dd",
    "diffAddFg" => "#5fbf87",
    "diffDelFg" => "#e5716e",
    "diffHunk" => "#7fd0d0",
    "diffAddBg" => "rgba(95, 191, 135, 0.11)",
    "diffDelBg" => "rgba(229, 113, 110, 0.1)",
    "cmGutterBg" => "rgba(18, 20, 23, 0.5)",
    "cmGutterFg" => "rgba(143, 150, 160, 0.45)",
    "cmActiveBg" => "rgba(27, 30, 35, 0.55)",
    "cmHunkBg" => "rgba(27, 30, 35, 0.6)",
    "cmSelection" => "#2d3f4d",
    "termBackground" => "#0b0c0e",
    "termForeground" => "#d7dde3",
    "termCursor" => "#4cc38a",
    "termCursorAccent" => "#0b0c0e",
    "termSelectionBackground" => "#2d3f4d",
    "ansiBlack" => "#1a1d21",
    "ansiRed" => "#e5716e",
    "ansiGreen" => "#5fbf87",
    "ansiYellow" => "#d9a860",
    "ansiBlue" => "#6d9fd6",
    "ansiMagenta" => "#b087c9",
    "ansiCyan" => "#5fb8b8",
    "ansiWhite" => "#c9ced4",
    "ansiBrightBlack" => "#5b626b",
    "ansiBrightRed" => "#f0928f",
    "ansiBrightGreen" => "#7fd6a3",
    "ansiBrightYellow" => "#ecc57f",
    "ansiBrightBlue" => "#8fb8e8",
    "ansiBrightMagenta" => "#c9a5dd",
    "ansiBrightCyan" => "#7fd0d0",
    "ansiBrightWhite" => "#e6e8eb"
  }

  @light %{
    "bg0" => "#fbfbfa",
    "bg1" => "#f3f3f1",
    "bg2" => "#e8e8e4",
    "line" => "#dcdcd6",
    "fg" => "#1c1e21",
    "fgMuted" => "#5f666e",
    "mint" => "#0c7a4f",
    "danger" => "#c92f2c",
    "gitAdded" => "#116329",
    "gitModified" => "#7a4b00",
    "gitDeleted" => "#705f66",
    "gitRenamed" => "#0550ae",
    "gitUntracked" => "#1b6b72",
    "gitConflict" => "#6639ba",
    "diffAddFg" => "#116329",
    "diffDelFg" => "#b31d28",
    "diffHunk" => "#0969da",
    "diffAddBg" => "#aae7ba",
    "diffDelBg" => "#ffd0cd",
    "cmGutterBg" => "rgba(0, 0, 0, 0.03)",
    "cmGutterFg" => "#5f666e",
    "cmActiveBg" => "rgba(0, 0, 0, 0.04)",
    "cmHunkBg" => "rgba(0, 0, 0, 0.05)",
    "cmSelection" => "#cfe3fb",
    "termBackground" => "#fbfbfa",
    "termForeground" => "#1c1e21",
    "termCursor" => "#0c7a4f",
    "termCursorAccent" => "#fbfbfa",
    "termSelectionBackground" => "#cfe3fb",
    "ansiBlack" => "#24292e",
    "ansiRed" => "#cf222e",
    "ansiGreen" => "#116329",
    "ansiYellow" => "#9a6700",
    "ansiBlue" => "#0969da",
    "ansiMagenta" => "#8250df",
    "ansiCyan" => "#1b7c83",
    "ansiWhite" => "#6e7781",
    "ansiBrightBlack" => "#57606a",
    "ansiBrightRed" => "#a40e26",
    "ansiBrightGreen" => "#1a7f37",
    "ansiBrightYellow" => "#7d4e00",
    "ansiBrightBlue" => "#218bff",
    "ansiBrightMagenta" => "#a475f9",
    "ansiBrightCyan" => "#3192aa",
    "ansiBrightWhite" => "#24292f"
  }

  @doc "The complete canonical palette for a base."
  def base_tokens(:dark), do: @dark
  def base_tokens(:light), do: @light
  def base_tokens("dark"), do: @dark
  def base_tokens("light"), do: @light

  def base_tokens(_base), do: nil

  @doc "Validate a sparse override and resolve all 45 tokens."
  def resolve(base, overrides \\ %{}) do
    with %{} = base_tokens <- base_tokens(base),
         {:ok, clean} <- Tokens.validate(overrides) do
      {:ok, Map.merge(base_tokens, clean)}
    else
      nil -> {:error, "base must be light or dark"}
      {:error, message} -> {:error, message}
    end
  end
end
