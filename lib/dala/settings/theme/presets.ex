defmodule Dala.Settings.Theme.Presets do
  @moduledoc """
  The six built-in, forkable, non-destructible theme presets.

  Each is a GLOBAL row (`owner_id` = the sentinel, `user_id` = nil,
  `builtin` = true) with a FIXED uuid, so a version bump can re-upsert the
  preset's colours (`ensure!/0`) without disturbing any user fork — forks are
  separate rows with their own generated ids.

  The ANSI 16 stay canonical so terminal programs retain their expected colour
  semantics. The surrounding shell uses a quieter three-step surface scale,
  legible secondary text and a palette-specific interaction accent; diff and
  CodeMirror chrome use restrained tints rather than competing with terminal
  content. All 45 tokens are filled even though sparse presets are allowed.

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
        "bg0" => "#001f27",
        "bg1" => "#002b36",
        "bg2" => "#073642",
        "line" => "#15505c",
        "fg" => "#d4dcda",
        "fgMuted" => "#8aa0a0",
        "mint" => "#2aa198",
        "danger" => "#e05a4f",
        "gitAdded" => "#a4b42c",
        "gitModified" => "#d5a21a",
        "gitDeleted" => "#ad9c95",
        "gitRenamed" => "#4aa3d8",
        "gitUntracked" => "#43b8ad",
        "gitConflict" => "#d979b2",
        "diffAddFg" => "#a4b42c",
        "diffDelFg" => "#ec6b62",
        "diffHunk" => "#43b8ad",
        "diffAddBg" => "rgba(133, 153, 0, 0.13)",
        "diffDelBg" => "rgba(220, 50, 47, 0.13)",
        "cmGutterBg" => "rgba(0, 31, 39, 0.6)",
        "cmGutterFg" => "rgba(138, 160, 160, 0.55)",
        "cmActiveBg" => "rgba(42, 161, 152, 0.07)",
        "cmHunkBg" => "rgba(42, 161, 152, 0.1)",
        "cmSelection" => "#164b56",
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
      tokens: %{
        "bg0" => "#fffdf6",
        "bg1" => "#f6f1e3",
        "bg2" => "#eae3d1",
        "line" => "#d8cfbb",
        "fg" => "#40575b",
        "fgMuted" => "#53686b",
        "mint" => "#147985",
        "danger" => "#c43d3d",
        "gitAdded" => "#657400",
        "gitModified" => "#8a5d00",
        "gitDeleted" => "#71615d",
        "gitRenamed" => "#1b6fa8",
        "gitUntracked" => "#147985",
        "gitConflict" => "#8f3f78",
        "diffAddFg" => "#586600",
        "diffDelFg" => "#b93636",
        "diffHunk" => "#268bd2",
        "diffAddBg" => "rgba(133, 153, 0, 0.14)",
        "diffDelBg" => "rgba(220, 50, 47, 0.11)",
        "cmGutterBg" => "rgba(0, 0, 0, 0.03)",
        "cmGutterFg" => "#829294",
        "cmActiveBg" => "rgba(20, 121, 133, 0.06)",
        "cmHunkBg" => "rgba(38, 139, 210, 0.07)",
        "cmSelection" => "#d7e6f5",
        "termBackground" => "#fdf6e3",
        "termForeground" => "#586e75",
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
        "bg0" => "#1e1f29",
        "bg1" => "#282a36",
        "bg2" => "#343746",
        "line" => "#484b5f",
        "fg" => "#f4f4ef",
        "fgMuted" => "#aeb2c7",
        "mint" => "#50fa7b",
        "danger" => "#ff5555",
        "gitAdded" => "#50fa7b",
        "gitModified" => "#f1fa8c",
        "gitDeleted" => "#b9aebf",
        "gitRenamed" => "#8be9fd",
        "gitUntracked" => "#69d9e7",
        "gitConflict" => "#ff79c6",
        "diffAddFg" => "#50fa7b",
        "diffDelFg" => "#ff6e6e",
        "diffHunk" => "#8be9fd",
        "diffAddBg" => "rgba(80, 250, 123, 0.13)",
        "diffDelBg" => "rgba(255, 85, 85, 0.14)",
        "cmGutterBg" => "rgba(30, 31, 41, 0.72)",
        "cmGutterFg" => "rgba(174, 178, 199, 0.5)",
        "cmActiveBg" => "rgba(139, 233, 253, 0.05)",
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
        "bg0" => "#242933",
        "bg1" => "#2e3440",
        "bg2" => "#394150",
        "line" => "#4b566a",
        "fg" => "#eceff4",
        "fgMuted" => "#aab4c6",
        "mint" => "#8fbcbb",
        "danger" => "#d57780",
        "gitAdded" => "#a3be8c",
        "gitModified" => "#ebcb8b",
        "gitDeleted" => "#aeb3bc",
        "gitRenamed" => "#81a1c1",
        "gitUntracked" => "#88c0d0",
        "gitConflict" => "#b48ead",
        "diffAddFg" => "#a3be8c",
        "diffDelFg" => "#e39198",
        "diffHunk" => "#88c0d0",
        "diffAddBg" => "rgba(163, 190, 140, 0.14)",
        "diffDelBg" => "rgba(191, 97, 106, 0.14)",
        "cmGutterBg" => "rgba(36, 41, 51, 0.7)",
        "cmGutterFg" => "rgba(170, 180, 198, 0.5)",
        "cmActiveBg" => "rgba(143, 188, 187, 0.06)",
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
        "bg0" => "#1d2021",
        "bg1" => "#282828",
        "bg2" => "#3c3836",
        "line" => "#504945",
        "fg" => "#ebdbb2",
        "fgMuted" => "#bdae93",
        "mint" => "#b8bb26",
        "danger" => "#fb4934",
        "gitAdded" => "#b8bb26",
        "gitModified" => "#fabd2f",
        "gitDeleted" => "#b8a88f",
        "gitRenamed" => "#83a598",
        "gitUntracked" => "#8ec07c",
        "gitConflict" => "#d3869b",
        "diffAddFg" => "#b8bb26",
        "diffDelFg" => "#ff705a",
        "diffHunk" => "#8ec07c",
        "diffAddBg" => "rgba(184, 187, 38, 0.13)",
        "diffDelBg" => "rgba(251, 73, 52, 0.14)",
        "cmGutterBg" => "rgba(29, 32, 33, 0.72)",
        "cmGutterFg" => "rgba(189, 174, 147, 0.5)",
        "cmActiveBg" => "rgba(184, 187, 38, 0.055)",
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
      tokens: %{
        "bg0" => "#ffffff",
        "bg1" => "#f6f8fa",
        "bg2" => "#eaeef2",
        "line" => "#d0d7de",
        "fg" => "#1f2328",
        "fgMuted" => "#656d76",
        "mint" => "#0969da",
        "danger" => "#cf222e",
        "gitAdded" => "#116329",
        "gitModified" => "#7d4e00",
        "gitDeleted" => "#6f6065",
        "gitRenamed" => "#0550ae",
        "gitUntracked" => "#1b6b72",
        "gitConflict" => "#6639ba",
        "diffAddFg" => "#1a7f37",
        "diffDelFg" => "#cf222e",
        "diffHunk" => "#0969da",
        "diffAddBg" => "#dafbe1",
        "diffDelBg" => "#ffebe9",
        "cmGutterBg" => "rgba(0, 0, 0, 0.03)",
        "cmGutterFg" => "#656d76",
        "cmActiveBg" => "rgba(9, 105, 218, 0.045)",
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
