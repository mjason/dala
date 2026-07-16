defmodule Dala.Settings.ThemePreviewTest do
  use ExUnit.Case, async: true

  alias Dala.Settings.Theme.{Audit, Palette, Presets, Svg}

  @snapshots %{
    "10000000-0000-0000-0000-000000000001" =>
      "8c1ce9c810a29e9215f1451424bdb078058e793496d61264aa4f425162096bfe",
    "10000000-0000-0000-0000-000000000002" =>
      "3d6f36213e274818a92a16df41a3c253ebe47aacc4a5d938d7f2f71b5fce1f4e",
    "10000000-0000-0000-0000-000000000003" =>
      "cab5d59391da17d573d87563a8993d3c0356ff4ae06e82a25fbdbd9b27817100",
    "10000000-0000-0000-0000-000000000004" =>
      "5bb07cd997b6bfd9e8ca9c55a2927e548ef709c8e34c5c78bdeb4757548d53b2",
    "10000000-0000-0000-0000-000000000005" =>
      "f767b7d09b9b8b01512509e1c20f115c261356bee485741de204250b82b148fb",
    "10000000-0000-0000-0000-000000000006" =>
      "cf863c429f6ca647b89ed406f396bf34a24bc05dd2c5518925aa65bb64cc1c91"
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
