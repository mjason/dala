defmodule Dala.ThemeRenderer do
  @moduledoc """
  Deterministic SVG-to-PNG rendering through the standalone
  `native/dala_theme_renderer` resvg/tiny-skia NIF.
  """

  use Rustler, otp_app: :dala, crate: "dala_theme_renderer"

  def render_png(_svg, _width, _height), do: :erlang.nif_error(:nif_not_loaded)
end
