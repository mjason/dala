defmodule Dala.Settings.ThemePreviewTest do
  use ExUnit.Case, async: true

  alias Dala.Settings.Theme.{Audit, Palette, Presets, Svg}

  @snapshots %{
    "10000000-0000-0000-0000-000000000001" =>
      "0449f53d4b34c498b88d9f97cac5f4036ae141bf6c49b331ca3fe095fedb5c9b",
    "10000000-0000-0000-0000-000000000002" =>
      "8ee4baa8781134fd44d366f3a2c882bb08ed5c427a9be291a328bbd9b89d7c4d",
    "10000000-0000-0000-0000-000000000003" =>
      "34ce8725bd04ecec1c9b20ce4c6e6a7045edf92f303919888c03a286b6ed7861",
    "10000000-0000-0000-0000-000000000004" =>
      "e8eb60f15f4d73793aff41733b39b7debfa8c87b6e77c75f4964fb307d7b72f7",
    "10000000-0000-0000-0000-000000000005" =>
      "4ff0296d33b9aacd45e1575a3739e5acd893420113a016f57cfe0e3de1d133d4",
    "10000000-0000-0000-0000-000000000006" =>
      "f873373389c9487738620a82d8e98165a86fdf7e3049e0e635ee87111a71d176"
  }

  test "sparse themes resolve to all 46 tokens without changing the base" do
    assert {:ok, tokens} = Palette.resolve(:dark, %{"gitAdded" => "#abcdef"})
    assert map_size(tokens) == 46
    assert tokens["gitAdded"] == "#abcdef"
    assert tokens["bg0"] == "#0b0c0e"
  end

  test "hard audit failures are explicit and do not collapse into one score" do
    {:ok, tokens} = Palette.resolve(:dark, %{"fg" => "#111111", "gitAdded" => "#121212"})
    report = Audit.run(tokens)

    refute report.passed
    assert Enum.any?(report.errors, &(&1.code == "contrast_body_text"))
    assert Enum.any?(report.errors, &(&1.code == "contrast_gitAdded_bg1"))
    refute Map.has_key?(report, :score)
    assert report.suggestions != []
  end

  test "the SVG scene is fixed, font-free and contains no external/user content" do
    svg = Svg.render(Palette.base_tokens(:dark))

    assert svg =~ ~s(width="1200" height="760")
    assert svg =~ "dala-theme-preview-v1"
    refute svg =~ "<text"
    refute svg =~ "<image"
    refute svg =~ "href="
    refute svg =~ "url("
  end

  test "all six presets pass audit and match deterministic PNG snapshots" do
    for preset <- Presets.all() do
      report = Audit.run(preset.tokens)
      assert report.passed, "#{preset.name}: #{inspect(report.errors)}"

      refute preset.tokens["gitDeleted"] == preset.tokens["danger"],
             "#{preset.name}: deleted files must not look like destructive actions"

      svg = Svg.render(preset.tokens)
      assert {:ok, png} = Dala.ThemeRenderer.render_png(svg, Svg.width(), Svg.height())
      assert <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>> = png
      assert png_dimensions(png) == {1200, 760}

      digest = :crypto.hash(:sha256, png) |> Base.encode16(case: :lower)
      assert digest == @snapshots[preset.id], "PNG snapshot changed for #{preset.name}"
    end
  end

  defp png_dimensions(
         <<137, 80, 78, 71, 13, 10, 26, 10, 13::32, "IHDR", width::32, height::32, _rest::binary>>
       ),
       do: {width, height}
end
