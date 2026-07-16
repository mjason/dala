defmodule Dala.Settings.Theme.Tokens do
  @moduledoc """
  The canonical custom-theme token contract: the 45 colour slots a theme may
  override, and the whitelist validator applied on every write.

  A theme's `tokens` map is a sparse `string -> string` map keyed by the names
  below (camelCase). Omitted keys fall back to the base (`:light` / `:dark`)
  palette on the client, so a preset or a user theme only needs to carry what
  it changes. On write we REJECT anything that isn't in this list, and any
  value that isn't a string.

  CLIENT CONTRACT — the browser side (`assets/js/app/themeTokens.ts`, built in
  the next phase) MUST use this identical key list, in these identical
  spellings. Adding or renaming a token means changing BOTH sides. The 45
  keys, grouped:

    * UI shell (8):   bg0 bg1 bg2 line fg fgMuted mint danger
    * Git states (6): gitAdded gitModified gitDeleted gitRenamed gitUntracked
                      gitConflict
    * diff (5):       diffAddFg diffDelFg diffHunk diffAddBg diffDelBg
    * CodeMirror (5): cmGutterBg cmGutterFg cmActiveBg cmHunkBg cmSelection
    * term base (5):  termBackground termForeground termCursor termCursorAccent
                      termSelectionBackground
    * ANSI (16):      ansiBlack ansiRed ansiGreen ansiYellow ansiBlue
                      ansiMagenta ansiCyan ansiWhite ansiBrightBlack
                      ansiBrightRed ansiBrightGreen ansiBrightYellow
                      ansiBrightBlue ansiBrightMagenta ansiBrightCyan
                      ansiBrightWhite
  """

  @token_keys ~w(
    bg0 bg1 bg2 line fg fgMuted mint danger
    gitAdded gitModified gitDeleted gitRenamed gitUntracked gitConflict
    diffAddFg diffDelFg diffHunk diffAddBg diffDelBg
    cmGutterBg cmGutterFg cmActiveBg cmHunkBg cmSelection
    termBackground termForeground termCursor termCursorAccent termSelectionBackground
    ansiBlack ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan ansiWhite
    ansiBrightBlack ansiBrightRed ansiBrightGreen ansiBrightYellow ansiBrightBlue
    ansiBrightMagenta ansiBrightCyan ansiBrightWhite
  )

  @doc "The 45 canonical token keys (strings, camelCase)."
  def token_keys, do: @token_keys

  @doc "How many canonical tokens there are (45)."
  def count, do: length(@token_keys)

  # A token value must be a plain CSS colour. This is a SECURITY boundary, not
  # cosmetics: values are injected client-side as `element.style.setProperty
  # ("--color-*", value)` and land in `background:` shorthands (app.css), so an
  # unvalidated `url(https://evil/x)` would make every device that renders the
  # (shared/global) theme fetch an attacker URL — a stored, cross-user tracking
  # beacon. We accept only hex, rgb(a)/hsl(a) with numeric/separator innards
  # (no letters that could spell `url(`), and `transparent`, all capped in
  # length. Anything else — url(), image-set(), expression(), oversized blobs —
  # is rejected on write.
  @max_value_len 64
  @color_keywords ~w(transparent)
  @hex ~r/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/
  @func ~r/^(?:rgb|rgba|hsl|hsla)\([0-9.,%\/\sdeg-]*\)$/

  defp valid_color?(value) when is_binary(value) do
    String.length(value) <= @max_value_len and
      (value in @color_keywords or Regex.match?(@hex, value) or Regex.match?(@func, value))
  end

  @doc """
  Validate and normalise a tokens map on write. Keys may arrive as atoms or
  strings; the result always has string keys.

  Returns `{:ok, clean}` when every key is one of the 45 canonical tokens and
  every value is a valid, length-bounded CSS colour, or `{:error, message}` on
  the first violation — unknown keys, non-string values, and anything that is
  not a plain colour (e.g. `url(...)`) are rejected, not silently dropped.
  """
  def validate(tokens) when is_map(tokens) do
    Enum.reduce_while(tokens, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      cond do
        key not in @token_keys ->
          {:halt, {:error, "unknown token key: #{key}"}}

        not is_binary(value) ->
          {:halt, {:error, "token #{key} must be a string, got: #{inspect(value)}"}}

        not valid_color?(value) ->
          {:halt, {:error, "token #{key} is not a valid CSS colour: #{inspect(value)}"}}

        true ->
          {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  def validate(_other), do: {:error, "tokens must be a map"}
end
