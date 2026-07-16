defmodule Dala.Settings.ThemePreviewTest do
  use ExUnit.Case, async: true

  alias Dala.Settings.Theme.{Audit, Palette, Presets, Svg}

  @snapshots %{
    "10000000-0000-0000-0000-000000000001" =>
      "9d15290f00c858b0cd02720de3997ef6fe77d1edb1166f30f56ad6ecda87409c",
    "10000000-0000-0000-0000-000000000002" =>
      "7a976655f9f74c06015441937985abc4b1b09ff8c9c70108dbdfc47f465ac7a7",
    "10000000-0000-0000-0000-000000000003" =>
      "b672519539dc912af7a1d585dd03c82d18fd21a69a402d5936b8563d9b542f8d",
    "10000000-0000-0000-0000-000000000004" =>
      "e74771bd43f3f12f0148a1b9c10fa5b8d61d8d294a2f058df590c4e7b0fa8088",
    "10000000-0000-0000-0000-000000000005" =>
      "950855388e97383415246fa674e4c24f883484f9b61bff022d70ea18a1935161",
    "10000000-0000-0000-0000-000000000006" =>
      "dcdac99d9f8098f901bc4b4d132958bd06854204516a905c6a3303c894ce5e00"
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
