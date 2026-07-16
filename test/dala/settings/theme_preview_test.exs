defmodule Dala.Settings.ThemePreviewTest do
  use ExUnit.Case, async: true

  alias Dala.Settings.Theme.{Audit, Palette, Presets, Svg}

  @snapshots %{
    "10000000-0000-0000-0000-000000000001" =>
      "0c9ba939822321b1f497d482790336c46bcb59b90eeb19a70eba1d7893a02ff7",
    "10000000-0000-0000-0000-000000000002" =>
      "e8624da4b4b8d28691e994a321bd02a429e2f5f06fe0274d392204828ea846f1",
    "10000000-0000-0000-0000-000000000003" =>
      "79cd7315f611384567c20e3b8526f2fe110ce2f4fe5f50d8db17e3d906b0562c",
    "10000000-0000-0000-0000-000000000004" =>
      "e6f544a816939bca53b7ed80f99c8e192d9dfd31016984fa02fd4d839d96511d",
    "10000000-0000-0000-0000-000000000005" =>
      "992227c166dd6ca1a20436ea322c4066402404d44824ab0b5b22733141e1828c",
    "10000000-0000-0000-0000-000000000006" =>
      "9af18b0e1d4c3ecbb80b88876c8d7e5873382ec218241f04bb0475d873ae5e72"
  }

  test "sparse themes resolve to all 45 tokens without changing the base" do
    assert {:ok, tokens} = Palette.resolve(:dark, %{"gitAdded" => "#abcdef"})
    assert map_size(tokens) == 45
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
