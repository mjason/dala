defmodule Dala.Settings.Theme.Presets do
  @moduledoc """
  The six built-in, forkable, non-destructible theme presets.

  Each is a GLOBAL row (`owner_id` = the sentinel, `user_id` = nil,
  `builtin` = true) with a FIXED uuid, so a version bump can re-upsert the
  preset's colours (`ensure!/0`) without disturbing any user fork — forks are
  separate rows with their own generated ids.

  Colour mapping (per the approved design): the ANSI 16 come straight from the
  palette's canonical terminal set; term base from its bg/fg/cursor/selection;
  the UI shell (bg0..danger) is chosen to match the palette's mood (bg0 = the
  darkest/lightest base, mint = the palette's green/accent, danger = its red);
  diff/CM chrome is derived (diffAddFg = green, diffDelFg = red, diffHunk =
  cyan/blue, row/gutter tints as low-alpha rgba). All 39 tokens are filled for
  clarity even though sparse presets are allowed.

  The two LIGHT presets (Solarized Light, GitHub Light) had their shell
  fg/mint/danger WCAG-checked against bg0 — see the notes inline. Where a
  canonical accent fell under the bar, the SHELL token was darkened (never the
  ANSI set).
  """

  # Fixed ids — never regenerate these. Distinct from the all-zero global
  # sentinel used for anonymous user rows.
  @solarized_dark "10000000-0000-0000-0000-000000000001"
  @solarized_light "10000000-0000-0000-0000-000000000002"
  @dracula "10000000-0000-0000-0000-000000000003"
  @nord "10000000-0000-0000-0000-000000000004"
  @gruvbox_dark "10000000-0000-0000-0000-000000000005"
  @github_light "10000000-0000-0000-0000-000000000006"

  @presets [
    %{
      id: @solarized_dark,
      name: "Solarized Dark",
      base: :dark,
      tokens: %{
        "bg0" => "#002b36",
        "bg1" => "#073642",
        "bg2" => "#0e4753",
        "line" => "#144d5c",
        "fg" => "#93a1a1",
        "fgMuted" => "#657b83",
        "mint" => "#859900",
        "danger" => "#dc322f",
        "diffAddFg" => "#859900",
        "diffDelFg" => "#dc322f",
        "diffHunk" => "#2aa198",
        "diffAddBg" => "rgba(133, 153, 0, 0.15)",
        "diffDelBg" => "rgba(220, 50, 47, 0.15)",
        "cmGutterBg" => "rgba(7, 54, 66, 0.5)",
        "cmGutterFg" => "rgba(101, 123, 131, 0.5)",
        "cmActiveBg" => "rgba(255, 255, 255, 0.04)",
        "cmHunkBg" => "rgba(42, 161, 152, 0.12)",
        "cmSelection" => "#073642",
        "termBackground" => "#002b36",
        "termForeground" => "#839496",
        "termCursor" => "#93a1a1",
        "termCursorAccent" => "#002b36",
        "termSelectionBackground" => "#073642",
        "ansiBlack" => "#073642",
        "ansiRed" => "#dc322f",
        "ansiGreen" => "#859900",
        "ansiYellow" => "#b58900",
        "ansiBlue" => "#268bd2",
        "ansiMagenta" => "#d33682",
        "ansiCyan" => "#2aa198",
        "ansiWhite" => "#eee8d5",
        "ansiBrightBlack" => "#002b36",
        "ansiBrightRed" => "#cb4b16",
        "ansiBrightGreen" => "#586e75",
        "ansiBrightYellow" => "#657b83",
        "ansiBrightBlue" => "#839496",
        "ansiBrightMagenta" => "#6c71c4",
        "ansiBrightCyan" => "#93a1a1",
        "ansiBrightWhite" => "#fdf6e3"
      }
    },
    %{
      id: @solarized_light,
      name: "Solarized Light",
      base: :light,
      # WCAG vs bg0 #fdf6e3 (all clear the 4.5 text bar — mint/danger double as
      # diff +N/-N text): fg #586e75 = 4.99; mint #657400 = 4.81 (canonical
      # green #859900 was only 2.97, so the shell accent was darkened); danger
      # #c92f2c = 4.96 (canonical red #dc322f was 4.29, under the text bar, so
      # darkened). fgMuted #556a70 = 5.29/4.65 on bg0/bg1 (clears the 4.5 bar for
      # muted labels/token-names) and 4.16 on the bg2 control-track chrome (over
      # the 3.0 UI bar); canonical base00 #657b83 was 4.13/3.64/3.25 and missed
      # it — note bg1/bg2 are dark enough here that even fg is 4.39/3.93, so a
      # muted colour cannot clear 4.5 on bg2 without going darker than fg. The
      # ANSI 16 stay canonical Solarized.
      tokens: %{
        "bg0" => "#fdf6e3",
        "bg1" => "#eee8d5",
        "bg2" => "#e3dcc6",
        "line" => "#d4cdb5",
        "fg" => "#586e75",
        "fgMuted" => "#556a70",
        "mint" => "#657400",
        "danger" => "#c92f2c",
        "diffAddFg" => "#657400",
        "diffDelFg" => "#c92f2c",
        "diffHunk" => "#268bd2",
        "diffAddBg" => "rgba(133, 153, 0, 0.18)",
        "diffDelBg" => "rgba(220, 50, 47, 0.14)",
        "cmGutterBg" => "rgba(0, 0, 0, 0.03)",
        "cmGutterFg" => "#93a1a1",
        "cmActiveBg" => "rgba(0, 0, 0, 0.04)",
        "cmHunkBg" => "rgba(38, 139, 210, 0.08)",
        "cmSelection" => "#d7e6f5",
        "termBackground" => "#fdf6e3",
        "termForeground" => "#657b83",
        "termCursor" => "#586e75",
        "termCursorAccent" => "#fdf6e3",
        "termSelectionBackground" => "#eee8d5",
        "ansiBlack" => "#073642",
        "ansiRed" => "#dc322f",
        "ansiGreen" => "#859900",
        "ansiYellow" => "#b58900",
        "ansiBlue" => "#268bd2",
        "ansiMagenta" => "#d33682",
        "ansiCyan" => "#2aa198",
        "ansiWhite" => "#eee8d5",
        "ansiBrightBlack" => "#002b36",
        "ansiBrightRed" => "#cb4b16",
        "ansiBrightGreen" => "#586e75",
        "ansiBrightYellow" => "#657b83",
        "ansiBrightBlue" => "#839496",
        "ansiBrightMagenta" => "#6c71c4",
        "ansiBrightCyan" => "#93a1a1",
        "ansiBrightWhite" => "#fdf6e3"
      }
    },
    %{
      id: @dracula,
      name: "Dracula",
      base: :dark,
      tokens: %{
        "bg0" => "#282a36",
        "bg1" => "#31333f",
        "bg2" => "#3b3d4d",
        "line" => "#44475a",
        "fg" => "#f8f8f2",
        "fgMuted" => "#6272a4",
        "mint" => "#50fa7b",
        "danger" => "#ff5555",
        "diffAddFg" => "#50fa7b",
        "diffDelFg" => "#ff5555",
        "diffHunk" => "#8be9fd",
        "diffAddBg" => "rgba(80, 250, 123, 0.13)",
        "diffDelBg" => "rgba(255, 85, 85, 0.14)",
        "cmGutterBg" => "rgba(33, 34, 44, 0.5)",
        "cmGutterFg" => "rgba(98, 114, 164, 0.6)",
        "cmActiveBg" => "rgba(255, 255, 255, 0.04)",
        "cmHunkBg" => "rgba(139, 233, 253, 0.1)",
        "cmSelection" => "#44475a",
        "termBackground" => "#282a36",
        "termForeground" => "#f8f8f2",
        "termCursor" => "#f8f8f2",
        "termCursorAccent" => "#282a36",
        "termSelectionBackground" => "#44475a",
        "ansiBlack" => "#21222c",
        "ansiRed" => "#ff5555",
        "ansiGreen" => "#50fa7b",
        "ansiYellow" => "#f1fa8c",
        "ansiBlue" => "#bd93f9",
        "ansiMagenta" => "#ff79c6",
        "ansiCyan" => "#8be9fd",
        "ansiWhite" => "#f8f8f2",
        "ansiBrightBlack" => "#6272a4",
        "ansiBrightRed" => "#ff6e6e",
        "ansiBrightGreen" => "#69ff94",
        "ansiBrightYellow" => "#ffffa5",
        "ansiBrightBlue" => "#d6acff",
        "ansiBrightMagenta" => "#ff92df",
        "ansiBrightCyan" => "#a4ffff",
        "ansiBrightWhite" => "#ffffff"
      }
    },
    %{
      id: @nord,
      name: "Nord",
      base: :dark,
      tokens: %{
        "bg0" => "#2e3440",
        "bg1" => "#3b4252",
        "bg2" => "#434c5e",
        "line" => "#4c566a",
        "fg" => "#eceff4",
        "fgMuted" => "#8a94a8",
        "mint" => "#a3be8c",
        "danger" => "#bf616a",
        "diffAddFg" => "#a3be8c",
        "diffDelFg" => "#bf616a",
        "diffHunk" => "#88c0d0",
        "diffAddBg" => "rgba(163, 190, 140, 0.14)",
        "diffDelBg" => "rgba(191, 97, 106, 0.14)",
        "cmGutterBg" => "rgba(59, 66, 82, 0.5)",
        "cmGutterFg" => "rgba(76, 86, 106, 0.9)",
        "cmActiveBg" => "rgba(255, 255, 255, 0.04)",
        "cmHunkBg" => "rgba(136, 192, 208, 0.1)",
        "cmSelection" => "#434c5e",
        "termBackground" => "#2e3440",
        "termForeground" => "#d8dee9",
        "termCursor" => "#d8dee9",
        "termCursorAccent" => "#2e3440",
        "termSelectionBackground" => "#434c5e",
        "ansiBlack" => "#3b4252",
        "ansiRed" => "#bf616a",
        "ansiGreen" => "#a3be8c",
        "ansiYellow" => "#ebcb8b",
        "ansiBlue" => "#81a1c1",
        "ansiMagenta" => "#b48ead",
        "ansiCyan" => "#88c0d0",
        "ansiWhite" => "#e5e9f0",
        "ansiBrightBlack" => "#4c566a",
        "ansiBrightRed" => "#bf616a",
        "ansiBrightGreen" => "#a3be8c",
        "ansiBrightYellow" => "#ebcb8b",
        "ansiBrightBlue" => "#81a1c1",
        "ansiBrightMagenta" => "#b48ead",
        "ansiBrightCyan" => "#8fbcbb",
        "ansiBrightWhite" => "#eceff4"
      }
    },
    %{
      id: @gruvbox_dark,
      name: "Gruvbox Dark",
      base: :dark,
      tokens: %{
        "bg0" => "#282828",
        "bg1" => "#3c3836",
        "bg2" => "#504945",
        "line" => "#665c54",
        "fg" => "#ebdbb2",
        "fgMuted" => "#a89984",
        "mint" => "#b8bb26",
        "danger" => "#fb4934",
        "diffAddFg" => "#b8bb26",
        "diffDelFg" => "#fb4934",
        "diffHunk" => "#8ec07c",
        "diffAddBg" => "rgba(184, 187, 38, 0.13)",
        "diffDelBg" => "rgba(251, 73, 52, 0.14)",
        "cmGutterBg" => "rgba(60, 56, 54, 0.5)",
        "cmGutterFg" => "rgba(168, 153, 132, 0.6)",
        "cmActiveBg" => "rgba(255, 255, 255, 0.04)",
        "cmHunkBg" => "rgba(142, 192, 124, 0.1)",
        "cmSelection" => "#504945",
        "termBackground" => "#282828",
        "termForeground" => "#ebdbb2",
        "termCursor" => "#ebdbb2",
        "termCursorAccent" => "#282828",
        "termSelectionBackground" => "#504945",
        "ansiBlack" => "#282828",
        "ansiRed" => "#cc241d",
        "ansiGreen" => "#98971a",
        "ansiYellow" => "#d79921",
        "ansiBlue" => "#458588",
        "ansiMagenta" => "#b16286",
        "ansiCyan" => "#689d6a",
        "ansiWhite" => "#a89984",
        "ansiBrightBlack" => "#928374",
        "ansiBrightRed" => "#fb4934",
        "ansiBrightGreen" => "#b8bb26",
        "ansiBrightYellow" => "#fabd2f",
        "ansiBrightBlue" => "#83a598",
        "ansiBrightMagenta" => "#d3869b",
        "ansiBrightCyan" => "#8ec07c",
        "ansiBrightWhite" => "#ebdbb2"
      }
    },
    %{
      id: @github_light,
      name: "GitHub Light",
      base: :light,
      # WCAG vs bg0 #ffffff: fg #1f2328 = 15.8; mint #1a7f37 = 5.08; danger
      # #cf222e = 5.36 — all clear the 4.5 text bar, no shell adjustment
      # needed.
      tokens: %{
        "bg0" => "#ffffff",
        "bg1" => "#f6f8fa",
        "bg2" => "#eaeef2",
        "line" => "#d0d7de",
        "fg" => "#1f2328",
        "fgMuted" => "#656d76",
        "mint" => "#1a7f37",
        "danger" => "#cf222e",
        "diffAddFg" => "#1a7f37",
        "diffDelFg" => "#cf222e",
        "diffHunk" => "#0969da",
        "diffAddBg" => "#dafbe1",
        "diffDelBg" => "#ffebe9",
        "cmGutterBg" => "rgba(0, 0, 0, 0.03)",
        "cmGutterFg" => "#656d76",
        "cmActiveBg" => "rgba(0, 0, 0, 0.04)",
        "cmHunkBg" => "rgba(9, 105, 218, 0.08)",
        "cmSelection" => "#cfe3fb",
        "termBackground" => "#ffffff",
        "termForeground" => "#1f2328",
        "termCursor" => "#0969da",
        "termCursorAccent" => "#ffffff",
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
    }
  ]

  @doc "The six preset definitions (`%{id, name, base, tokens}`)."
  def all, do: @presets

  @doc "The fixed ids of the built-in presets."
  def ids, do: Enum.map(@presets, & &1.id)

  @doc """
  Idempotently upsert the six presets as global built-in rows, keyed by their
  fixed ids. Safe to call at every boot: on conflict it refreshes name/base/
  tokens/builtin, leaving user forks (separate rows) untouched.
  """
  def ensure! do
    global_id = Dala.Settings.Theme.global_id()

    Enum.each(@presets, fn preset ->
      Dala.Settings.Theme
      |> Ash.Changeset.for_create(
        :seed_preset,
        Map.merge(preset, %{owner_id: global_id, user_id: nil, builtin: true}),
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
    end)

    :ok
  end
end
