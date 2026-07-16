defmodule Dala.Settings.ThemeColorTest do
  use ExUnit.Case, async: true

  alias Dala.Settings.Theme.{Audit, Color, Palette}

  describe "CSS colour parsing" do
    test "supports the validated hex, rgb(a), hsl(a), percentage and transparent forms" do
      assert {:ok, {red_r, red_g, red_b, red_a}} = Color.parse("#f00")
      assert_in_delta red_r, 1.0, 0.001
      assert_in_delta red_g, 0.0, 0.001
      assert_in_delta red_b, 0.0, 0.001
      assert_in_delta red_a, 1.0, 0.001

      assert {:ok, {hex_r, hex_g, hex_b, alpha}} = Color.parse("#ff000080")
      assert_in_delta hex_r, 1.0, 0.001
      assert_in_delta hex_g, 0.0, 0.001
      assert_in_delta hex_b, 0.0, 0.001
      assert_in_delta alpha, 0.502, 0.001

      assert {:ok, rgba} = Color.parse("rgba(255, 0, 0, 0.5)")
      assert_rgba(rgba, {1.0, 0.0, 0.0, 0.5})
      assert {:ok, percentage} = Color.parse("rgb(100% 0% 0% / 25%)")
      assert_rgba(percentage, {1.0, 0.0, 0.0, 0.25})

      assert {:ok, {green_r, green_g, green_b, 1.0}} = Color.parse("hsl(120, 100%, 50%)")
      assert_in_delta green_r, 0.0, 0.001
      assert_in_delta green_g, 1.0, 0.001
      assert_in_delta green_b, 0.0, 0.001

      assert {:ok, {_r, _g, _b, 0.4}} = Color.parse("hsla(240 100% 50% / 40%)")
      assert {:ok, transparent} = Color.parse("transparent")
      assert_rgba(transparent, {0.0, 0.0, 0.0, 0.0})
    end

    test "rejects malformed colours and exposes contrast/distance/hue helpers" do
      assert {:error, _message} = Color.parse("rgb(1,,)")
      assert {:error, _message} = Color.parse("chartreuse")
      assert {:ok, ratio} = Color.contrast("#000000", "#ffffff")
      assert_in_delta ratio, 21.0, 0.001
      assert {:ok, distance} = Color.distance("#000000", "#ffffff")
      assert_in_delta distance, :math.sqrt(3), 0.001
      assert {:ok, {hue, saturation, _lightness}} = Color.hue("#00ff00")
      assert_in_delta hue, 120.0, 0.001
      assert_in_delta saturation, 1.0, 0.001
    end
  end

  describe "audit heuristics" do
    test "keeps hard failures separate from all five warning families" do
      {:ok, base} = Palette.resolve(:dark)

      tokens =
        base
        |> Map.merge(%{"bg1" => base["bg0"], "bg2" => base["bg0"], "fg" => "#101010"})
        |> then(fn tokens ->
          semantic =
            ~w(gitAdded gitModified gitDeleted gitRenamed gitUntracked gitConflict
               diffAddFg diffDelFg diffHunk ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan)

          Enum.reduce(semantic, tokens, &Map.put(&2, &1, "#ff0000"))
        end)
        |> then(fn tokens ->
          Enum.reduce(
            ~w(ansiBlack ansiRed ansiGreen ansiYellow ansiBlue ansiMagenta ansiCyan ansiWhite
               ansiBrightBlack ansiBrightRed ansiBrightGreen ansiBrightYellow ansiBrightBlue
               ansiBrightMagenta ansiBrightCyan ansiBrightWhite),
            tokens,
            &Map.put(&2, &1, tokens["termBackground"])
          )
        end)
        |> Map.put("mint", "#ff0000")

      report = Audit.run(tokens)
      warning_codes = MapSet.new(report.warnings, & &1.code)

      refute report.passed
      assert report.errors != []

      assert MapSet.subset?(
               MapSet.new(~w(backgrounds_too_close accent_overused git_colours_too_close
                             ansi_colours_invisible palette_single_hue)),
               warning_codes
             )

      refute Map.has_key?(report, :score)
    end

    test "rejects a syntactically allowed but unrenderable colour" do
      {:ok, tokens} = Palette.resolve(:dark, %{"bg0" => "rgb(1,,)"})
      assert {:error, message} = Audit.validate_colors(tokens)
      assert message =~ "not a renderable CSS colour"
    end
  end

  defp assert_rgba({r, g, b, a}, {expected_r, expected_g, expected_b, expected_a}) do
    assert_in_delta r, expected_r, 0.001
    assert_in_delta g, expected_g, 0.001
    assert_in_delta b, expected_b, 0.001
    assert_in_delta a, expected_a, 0.001
  end
end
