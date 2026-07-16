defmodule Dala.Settings.Theme.Audit do
  @moduledoc """
  Deterministic theme readability and palette review.

  Hard failures cover text that must remain readable. Heuristic observations
  are warnings only; there is deliberately no single beauty score to optimise.
  """

  alias Dala.Settings.Theme.Color

  @git_tokens ~w(gitAdded gitModified gitDeleted gitRenamed gitUntracked gitConflict)
  @ansi_tokens ~w(ansiBlack ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan ansiWhite
                  ansiBrightBlack ansiBrightRed ansiBrightGreen ansiBrightYellow ansiBrightBlue
                  ansiBrightMagenta ansiBrightCyan ansiBrightWhite)

  @doc "Check every resolved token can be interpreted by the preview renderer."
  def validate_colors(tokens) do
    Enum.reduce_while(tokens, :ok, fn {key, value}, :ok ->
      case Color.parse(value) do
        {:ok, _rgba} ->
          {:cont, :ok}

        {:error, _reason} ->
          {:halt, {:error, "token #{key} is not a renderable CSS colour: #{inspect(value)}"}}
      end
    end)
  end

  @doc "Return hard checks, warnings and concrete suggestions for a complete palette."
  def run(tokens) do
    hard_checks =
      [
        contrast_check(tokens, "body_text", "fg", "bg0", 4.5),
        contrast_check(tokens, "secondary_text", "fgMuted", "bg1", 4.5),
        contrast_check(tokens, "primary_button", "bg0", "mint", 4.5),
        contrast_check(tokens, "danger_button", "bg0", "danger", 4.5),
        contrast_check(tokens, "terminal_text", "termForeground", "termBackground", 4.5),
        contrast_check(tokens, "diff_added", "diffAddFg", "diffAddBg", 4.5, "bg0"),
        contrast_check(tokens, "diff_deleted", "diffDelFg", "diffDelBg", 4.5, "bg0")
      ] ++ git_checks(tokens)

    errors =
      for %{passed: false} = check <- hard_checks do
        %{
          code: "contrast_#{check.id}",
          message:
            "#{check.foreground} on #{check.background} is #{format_ratio(check.ratio)}:1; " <>
              "requires at least #{format_ratio(check.minimum)}:1",
          tokens: [check.foreground, check.background],
          ratio: round_ratio(check.ratio),
          minimum: check.minimum
        }
      end

    warnings =
      background_warnings(tokens) ++
        accent_warnings(tokens) ++
        git_similarity_warnings(tokens) ++
        ansi_warnings(tokens) ++ hue_warnings(tokens)

    suggestions = Enum.map(errors, &suggestion_for/1) ++ Enum.map(warnings, & &1.suggestion)

    %{
      passed: errors == [],
      hard_checks: hard_checks,
      errors: errors,
      warnings: warnings,
      suggestions: Enum.uniq(suggestions)
    }
  end

  defp git_checks(tokens) do
    for token <- @git_tokens, background <- ["bg1", "bg2"] do
      contrast_check(tokens, "#{token}_#{background}", token, background, 3.0)
    end
  end

  defp contrast_check(tokens, id, foreground, background, minimum, canvas \\ nil) do
    {:ok, ratio} =
      Color.contrast(
        Map.fetch!(tokens, foreground),
        Map.fetch!(tokens, background),
        Map.get(tokens, canvas || background, "#ffffff")
      )

    %{
      id: id,
      foreground: foreground,
      background: background,
      ratio: round_ratio(ratio),
      minimum: minimum,
      passed: ratio >= minimum
    }
  end

  defp background_warnings(tokens) do
    for {left, right} <- [{"bg0", "bg1"}, {"bg1", "bg2"}],
        {:ok, ratio} = Color.contrast(tokens[left], tokens[right]),
        ratio < 1.08 do
      warning(
        "backgrounds_too_close",
        "#{left} and #{right} are difficult to distinguish (#{format_ratio(ratio)}:1)",
        [left, right],
        "Increase separation between the three background layers."
      )
    end
  end

  defp accent_warnings(tokens) do
    semantic =
      ~w(gitAdded gitModified gitDeleted gitRenamed gitUntracked gitConflict diffAddFg diffDelFg diffHunk)

    repeated = Enum.count(semantic, &(normalize(tokens[&1]) == normalize(tokens["mint"])))

    if repeated >= 4 do
      [
        warning(
          "accent_overused",
          "The primary accent is reused by #{repeated} semantic status colours.",
          ["mint" | semantic],
          "Reserve the primary accent for commands and vary semantic status colours."
        )
      ]
    else
      []
    end
  end

  defp git_similarity_warnings(tokens) do
    pairs = for left <- @git_tokens, right <- @git_tokens, left < right, do: {left, right}

    close =
      for {left, right} <- pairs,
          {:ok, distance} = Color.distance(tokens[left], tokens[right]),
          distance < 0.08,
          do: {left, right}

    if close == [] do
      []
    else
      labels = Enum.map_join(close, ", ", fn {left, right} -> "#{left}/#{right}" end)

      [
        warning(
          "git_colours_too_close",
          "Some Git states are visually too similar: #{labels}.",
          close |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq(),
          "Separate Git state hues or lightness so adjacent labels remain scannable."
        )
      ]
    end
  end

  defp ansi_warnings(tokens) do
    invisible =
      Enum.filter(@ansi_tokens, fn token ->
        {:ok, ratio} = Color.contrast(tokens[token], tokens["termBackground"])
        ratio < 2.0
      end)

    if length(invisible) >= 6 do
      [
        warning(
          "ansi_colours_invisible",
          "#{length(invisible)} ANSI colours have less than 2:1 contrast on the terminal background.",
          invisible,
          "Lift dark ANSI colours or darken the terminal background so terminal output stays visible."
        )
      ]
    else
      []
    end
  end

  defp hue_warnings(tokens) do
    palette =
      ~w(mint danger gitAdded gitModified gitDeleted gitRenamed gitUntracked gitConflict
         diffAddFg diffDelFg diffHunk ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan)

    hues =
      for token <- palette,
          {:ok, {hue, saturation, _lightness}} = Color.hue(tokens[token]),
          saturation >= 0.25,
          do: hue

    buckets = Enum.frequencies_by(hues, &trunc(&1 / 30))
    dominant = buckets |> Map.values() |> Enum.max(fn -> 0 end)

    if length(hues) >= 10 and dominant / length(hues) >= 0.7 do
      [
        warning(
          "palette_single_hue",
          "The semantic palette is heavily concentrated in one hue family.",
          palette,
          "Introduce one or two distinct hue families for status and destructive actions."
        )
      ]
    else
      []
    end
  end

  defp warning(code, message, tokens, suggestion) do
    %{code: code, message: message, tokens: tokens, suggestion: suggestion}
  end

  defp suggestion_for(%{tokens: [foreground, background | _rest]}) do
    "Increase the lightness or hue separation of #{foreground} against #{background}."
  end

  defp normalize(value), do: value |> String.trim() |> String.downcase()
  defp round_ratio(value), do: Float.round(value, 2)
  defp format_ratio(value), do: value |> round_ratio() |> :erlang.float_to_binary(decimals: 2)
end
