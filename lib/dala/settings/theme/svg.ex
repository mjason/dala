defmodule Dala.Settings.Theme.Svg do
  @moduledoc """
  Fixed, content-free Dala preview scene rendered entirely from vector shapes.

  There are intentionally no SVG text nodes or external assets. This keeps the
  PNG independent of installed fonts and identical on Linux and macOS ARM64.
  """

  @width 1200
  @height 760

  def width, do: @width
  def height, do: @height

  def render(t) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@width}" height="#{@height}" viewBox="0 0 #{@width} #{@height}" shape-rendering="geometricPrecision">
      <metadata>dala-theme-preview-v1</metadata>
      <rect width="1200" height="760" fill="#{t["bg0"]}"/>

      <!-- top command bar -->
      <rect x="0" y="0" width="1200" height="46" fill="#{t["bg1"]}"/>
      <path d="M0 45.5H1200" stroke="#{t["line"]}"/>
      <rect x="18" y="14" width="84" height="7" rx="3.5" fill="#{t["fg"]}"/>
      <rect x="18" y="27" width="52" height="5" rx="2.5" fill="#{t["fgMuted"]}"/>
      <rect x="944" y="10" width="102" height="27" rx="5" fill="#{t["mint"]}"/>
      <rect x="966" y="21" width="58" height="5" rx="2.5" fill="#{t["bg0"]}"/>
      <rect x="1056" y="10" width="126" height="27" rx="5" fill="none" stroke="#{t["danger"]}"/>
      <rect x="1080" y="21" width="78" height="5" rx="2.5" fill="#{t["danger"]}"/>

      <!-- sessions sidebar -->
      <rect x="0" y="46" width="180" height="714" fill="#{t["bg1"]}"/>
      <path d="M179.5 46V760" stroke="#{t["line"]}"/>
      <rect x="14" y="64" width="80" height="6" rx="3" fill="#{t["fgMuted"]}"/>
      <rect x="10" y="84" width="160" height="40" rx="5" fill="#{t["bg2"]}"/>
      <circle cx="26" cy="104" r="4" fill="#{t["mint"]}"/>
      <rect x="38" y="96" width="82" height="6" rx="3" fill="#{t["fg"]}"/>
      <rect x="38" y="108" width="54" height="4" rx="2" fill="#{t["fgMuted"]}"/>
      <circle cx="26" cy="146" r="4" fill="#{t["gitModified"]}"/>
      <rect x="38" y="139" width="70" height="6" rx="3" fill="#{t["fg"]}"/>
      <rect x="38" y="151" width="42" height="4" rx="2" fill="#{t["fgMuted"]}"/>
      <circle cx="26" cy="188" r="4" fill="#{t["fgMuted"]}"/>
      <rect x="38" y="181" width="96" height="6" rx="3" fill="#{t["fg"]}"/>
      <rect x="38" y="193" width="61" height="4" rx="2" fill="#{t["fgMuted"]}"/>

      <!-- terminal -->
      <rect x="180" y="46" width="620" height="372" fill="#{t["termBackground"]}"/>
      <path d="M180 417.5H800" stroke="#{t["line"]}"/>
      <rect x="204" y="72" width="8" height="8" rx="2" fill="#{t["ansiGreen"]}"/>
      <rect x="222" y="73" width="72" height="6" rx="3" fill="#{t["termForeground"]}"/>
      <rect x="304" y="73" width="116" height="6" rx="3" fill="#{t["ansiCyan"]}"/>
      <rect x="204" y="96" width="218" height="6" rx="3" fill="#{t["termForeground"]}" opacity="0.82"/>
      <rect x="432" y="96" width="86" height="6" rx="3" fill="#{t["ansiBlue"]}"/>
      <rect x="204" y="119" width="315" height="6" rx="3" fill="#{t["termForeground"]}" opacity="0.72"/>
      <rect x="204" y="143" width="112" height="6" rx="3" fill="#{t["ansiYellow"]}"/>
      <rect x="326" y="143" width="258" height="6" rx="3" fill="#{t["termForeground"]}" opacity="0.68"/>
      <rect x="204" y="179" width="520" height="84" rx="4" fill="#{t["termSelectionBackground"]}" opacity="0.45"/>
      <rect x="222" y="198" width="305" height="6" rx="3" fill="#{t["termForeground"]}"/>
      <rect x="222" y="219" width="188" height="6" rx="3" fill="#{t["ansiMagenta"]}"/>
      <rect x="420" y="219" width="242" height="6" rx="3" fill="#{t["termForeground"]}" opacity="0.72"/>
      <rect x="222" y="240" width="390" height="6" rx="3" fill="#{t["ansiBrightBlack"]}"/>
      <rect x="204" y="287" width="8" height="8" rx="2" fill="#{t["ansiGreen"]}"/>
      <rect x="222" y="288" width="92" height="6" rx="3" fill="#{t["termForeground"]}"/>
      <rect x="323" y="284" width="2" height="14" fill="#{t["termCursor"]}"/>

      <!-- file tree with seven explicit Git status glyphs -->
      <rect x="800" y="46" width="400" height="372" fill="#{t["bg1"]}"/>
      <path d="M800.5 46V418" stroke="#{t["line"]}"/>
      <rect x="820" y="66" width="92" height="7" rx="3.5" fill="#{t["fg"]}"/>
      <rect x="1161" y="64" width="18" height="12" rx="3" fill="#{t["bg2"]}" stroke="#{t["line"]}"/>
      #{file_row(88, 0, 116, "A", t["gitAdded"], t)}
      #{file_row(120, 14, 156, "M", t["gitModified"], t)}
      #{file_row(152, 14, 132, "D", t["gitDeleted"], t)}
      #{file_row(184, 28, 178, "R", t["gitRenamed"], t)}
      #{file_row(216, 28, 142, "U", t["gitUntracked"], t)}
      #{file_row(248, 14, 166, "!", t["gitConflict"], t)}
      #{file_row(280, 14, 148, "I", t["gitIgnored"], t)}

      <!-- diff review -->
      <rect x="180" y="418" width="500" height="268" fill="#{t["bg0"]}"/>
      <path d="M679.5 418V686" stroke="#{t["line"]}"/>
      <rect x="198" y="438" width="84" height="6" rx="3" fill="#{t["fg"]}"/>
      <rect x="198" y="458" width="464" height="22" fill="#{t["cmHunkBg"]}"/>
      <rect x="212" y="466" width="124" height="5" rx="2.5" fill="#{t["diffHunk"]}"/>
      <rect x="198" y="480" width="464" height="31" fill="#{t["diffDelBg"]}"/>
      <rect x="212" y="493" width="8" height="5" rx="2" fill="#{t["diffDelFg"]}"/>
      <rect x="230" y="493" width="274" height="5" rx="2.5" fill="#{t["fg"]}"/>
      <rect x="198" y="511" width="464" height="31" fill="#{t["diffAddBg"]}"/>
      <rect x="212" y="524" width="8" height="5" rx="2" fill="#{t["diffAddFg"]}"/>
      <rect x="230" y="524" width="310" height="5" rx="2.5" fill="#{t["fg"]}"/>
      <rect x="230" y="560" width="246" height="5" rx="2.5" fill="#{t["fgMuted"]}"/>
      <rect x="230" y="583" width="328" height="5" rx="2.5" fill="#{t["fgMuted"]}"/>
      <rect x="230" y="606" width="212" height="5" rx="2.5" fill="#{t["fgMuted"]}"/>

      <!-- editor -->
      <rect x="680" y="418" width="520" height="268" fill="#{t["bg0"]}"/>
      <rect x="680" y="418" width="48" height="268" fill="#{t["cmGutterBg"]}"/>
      <rect x="694" y="448" width="18" height="5" rx="2.5" fill="#{t["cmGutterFg"]}"/>
      <rect x="694" y="476" width="18" height="5" rx="2.5" fill="#{t["cmGutterFg"]}"/>
      <rect x="680" y="490" width="520" height="28" fill="#{t["cmActiveBg"]}"/>
      <rect x="694" y="502" width="18" height="5" rx="2.5" fill="#{t["cmGutterFg"]}"/>
      <rect x="746" y="448" width="88" height="6" rx="3" fill="#{t["ansiMagenta"]}"/>
      <rect x="844" y="448" width="184" height="6" rx="3" fill="#{t["fg"]}"/>
      <rect x="768" y="476" width="116" height="6" rx="3" fill="#{t["ansiBlue"]}"/>
      <rect x="894" y="476" width="154" height="6" rx="3" fill="#{t["ansiGreen"]}"/>
      <rect x="768" y="502" width="228" height="6" rx="3" fill="#{t["fg"]}"/>
      <rect x="1006" y="502" width="74" height="6" rx="3" fill="#{t["ansiYellow"]}"/>
      <rect x="768" y="530" width="284" height="6" rx="3" fill="#{t["fgMuted"]}"/>
      <rect x="768" y="558" width="188" height="6" rx="3" fill="#{t["fg"]}"/>
      <rect x="966" y="558" width="92" height="6" rx="3" fill="#{t["ansiCyan"]}"/>
      <rect x="762" y="582" width="330" height="19" rx="3" fill="#{t["cmSelection"]}" opacity="0.75"/>
      <rect x="768" y="589" width="248" height="5" rx="2.5" fill="#{t["fg"]}"/>

      <!-- composer input -->
      <rect x="180" y="686" width="1020" height="74" fill="#{t["bg1"]}"/>
      <path d="M180 686.5H1200" stroke="#{t["line"]}"/>
      <rect x="198" y="701" width="852" height="43" rx="6" fill="#{t["bg0"]}" stroke="#{t["line"]}"/>
      <rect x="216" y="720" width="328" height="6" rx="3" fill="#{t["fgMuted"]}"/>
      <rect x="1064" y="701" width="118" height="43" rx="6" fill="#{t["mint"]}"/>
      <path d="M1107 714L1122 722L1107 730Z" fill="#{t["bg0"]}"/>
    </svg>
    """
  end

  defp file_row(y, indent, width, glyph, color, t) do
    x = 820 + indent

    """
    <rect x="812" y="#{y}" width="376" height="28" rx="4" fill="#{t["bg2"]}" opacity="0.34"/>
    <rect x="#{x}" y="#{y + 10}" width="10" height="8" rx="2" fill="#{t["fgMuted"]}" opacity="0.65"/>
    <rect x="#{x + 20}" y="#{y + 11}" width="#{width}" height="6" rx="3" fill="#{t["fg"]}"/>
    #{status_glyph(1160, y + 8, glyph, color)}
    """
  end

  defp status_glyph(x, y, "A", color),
    do:
      ~s(<path d="M#{x} #{y + 12}L#{x + 5} #{y}L#{x + 10} #{y + 12}M#{x + 2} #{y + 7}H#{x + 8}" fill="none" stroke="#{color}" stroke-width="2"/>)

  defp status_glyph(x, y, "M", color),
    do:
      ~s(<path d="M#{x} #{y + 12}V#{y}L#{x + 5} #{y + 7}L#{x + 10} #{y}V#{y + 12}" fill="none" stroke="#{color}" stroke-width="2"/>)

  defp status_glyph(x, y, "D", color),
    do:
      ~s(<path d="M#{x} #{y}V#{y + 12}H#{x + 3}C#{x + 12} #{y + 12} #{x + 12} #{y} #{x + 3} #{y}Z" fill="none" stroke="#{color}" stroke-width="2"/>)

  defp status_glyph(x, y, "R", color),
    do:
      ~s(<path d="M#{x} #{y + 12}V#{y}H#{x + 5}C#{x + 11} #{y} #{x + 11} #{y + 6} #{x + 5} #{y + 6}H#{x}M#{x + 5} #{y + 6}L#{x + 11} #{y + 12}" fill="none" stroke="#{color}" stroke-width="2"/>)

  defp status_glyph(x, y, "U", color),
    do:
      ~s(<path d="M#{x} #{y}V#{y + 7}C#{x} #{y + 14} #{x + 10} #{y + 14} #{x + 10} #{y + 7}V#{y}" fill="none" stroke="#{color}" stroke-width="2"/>)

  defp status_glyph(x, y, "!", color),
    do:
      ~s(<path d="M#{x + 5} #{y}V#{y + 8}M#{x + 5} #{y + 11}V#{y + 12}" fill="none" stroke="#{color}" stroke-width="2.5"/>)

  defp status_glyph(x, y, "I", color),
    do:
      ~s(<path d="M#{x + 2} #{y}H#{x + 8}M#{x + 5} #{y}V#{y + 12}M#{x + 2} #{y + 12}H#{x + 8}" fill="none" stroke="#{color}" stroke-width="2"/>)
end
