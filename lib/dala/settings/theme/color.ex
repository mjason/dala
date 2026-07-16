defmodule Dala.Settings.Theme.Color do
  @moduledoc false

  @type rgba :: {float(), float(), float(), float()}

  def parse("transparent"), do: {:ok, {0.0, 0.0, 0.0, 0.0}}

  def parse("#" <> hex) when byte_size(hex) in [3, 4, 6, 8] do
    values =
      case byte_size(hex) do
        size when size in [3, 4] -> hex |> String.graphemes() |> Enum.map(&(&1 <> &1))
        _ -> for <<pair::binary-size(2) <- hex>>, do: pair
      end

    with {:ok, channels} <- parse_hex_channels(values) do
      [r, g, b | alpha] = channels
      {:ok, {r / 255, g / 255, b / 255, (List.first(alpha) || 255) / 255}}
    end
  end

  def parse(value) when is_binary(value) do
    cond do
      Regex.match?(~r/^rgba?\(/i, value) -> parse_rgb(value)
      Regex.match?(~r/^hsla?\(/i, value) -> parse_hsl(value)
      true -> {:error, "unsupported colour: #{value}"}
    end
  end

  def parse(_value), do: {:error, "colour must be a string"}

  def contrast(foreground, background, canvas \\ "#ffffff") do
    with {:ok, fg} <- parse(foreground),
         {:ok, bg} <- parse(background),
         {:ok, base} <- parse(canvas) do
      bg = composite(bg, base)
      fg = composite(fg, bg)
      {darker, lighter} = Enum.min_max([luminance(fg), luminance(bg)])
      {:ok, (lighter + 0.05) / (darker + 0.05)}
    end
  end

  def distance(left, right) do
    with {:ok, {lr, lg, lb, _}} <- parse(left),
         {:ok, {rr, rg, rb, _}} <- parse(right) do
      {:ok, :math.sqrt(:math.pow(lr - rr, 2) + :math.pow(lg - rg, 2) + :math.pow(lb - rb, 2))}
    end
  end

  def hue(value) do
    with {:ok, {r, g, b, _}} <- parse(value) do
      max_channel = max(r, max(g, b))
      min_channel = min(r, min(g, b))
      delta = max_channel - min_channel
      lightness = (max_channel + min_channel) / 2

      saturation =
        if delta == 0, do: 0.0, else: delta / (1 - abs(2 * lightness - 1))

      hue =
        cond do
          delta == 0 -> 0.0
          max_channel == r -> 60 * :math.fmod((g - b) / delta, 6)
          max_channel == g -> 60 * ((b - r) / delta + 2)
          true -> 60 * ((r - g) / delta + 4)
        end

      {:ok, {if(hue < 0, do: hue + 360, else: hue), saturation, lightness}}
    end
  end

  defp parse_hex_channels(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Integer.parse(value, 16) do
        {channel, ""} -> {:cont, {:ok, acc ++ [channel]}}
        _ -> {:halt, {:error, "invalid hex colour"}}
      end
    end)
  end

  defp parse_rgb(value) do
    with [_, body] <- Regex.run(~r/^rgba?\((.*)\)$/i, value),
         [channels, alpha] <- split_alpha(body),
         [r, g, b] <- components(channels),
         {:ok, r} <- rgb_channel(r),
         {:ok, g} <- rgb_channel(g),
         {:ok, b} <- rgb_channel(b),
         {:ok, a} <- alpha_channel(alpha) do
      {:ok, {r, g, b, a}}
    else
      _ -> {:error, "invalid rgb colour: #{value}"}
    end
  end

  defp parse_hsl(value) do
    with [_, body] <- Regex.run(~r/^hsla?\((.*)\)$/i, value),
         [channels, alpha] <- split_alpha(body),
         [h, s, l] <- components(channels),
         {h, ""} <- h |> String.replace_suffix("deg", "") |> Float.parse(),
         {:ok, s} <- percentage(s),
         {:ok, l} <- percentage(l),
         {:ok, a} <- alpha_channel(alpha) do
      {r, g, b} = hsl_to_rgb(h, s, l)
      {:ok, {r, g, b, a}}
    else
      _ -> {:error, "invalid hsl colour: #{value}"}
    end
  end

  defp split_alpha(body) do
    parts = String.split(body, "/", parts: 2)

    case parts do
      [channels, alpha] ->
        [channels, String.trim(alpha)]

      [channels] ->
        values = components(channels)

        if length(values) == 4,
          do: [Enum.take(values, 3), List.last(values)],
          else: [channels, "1"]
    end
  end

  defp components(values) when is_list(values), do: values

  defp components(value) do
    value
    |> String.trim()
    |> String.split(~r/[\s,]+/, trim: true)
  end

  defp rgb_channel(value) do
    if String.ends_with?(value, "%") do
      with {:ok, percentage} <- percentage(value), do: {:ok, clamp(percentage)}
    else
      case Float.parse(value) do
        {number, ""} -> {:ok, clamp(number / 255)}
        _ -> {:error, :invalid}
      end
    end
  end

  defp alpha_channel(value) do
    if String.ends_with?(value, "%") do
      percentage(value)
    else
      case Float.parse(value) do
        {number, ""} -> {:ok, clamp(number)}
        _ -> {:error, :invalid}
      end
    end
  end

  defp percentage(value) do
    case value |> String.trim() |> String.replace_suffix("%", "") |> Float.parse() do
      {number, ""} -> {:ok, clamp(number / 100)}
      _ -> {:error, :invalid}
    end
  end

  defp hsl_to_rgb(hue, saturation, lightness) do
    chroma = (1 - abs(2 * lightness - 1)) * saturation
    section = :math.fmod(hue / 60, 6)
    x = chroma * (1 - abs(:math.fmod(section, 2) - 1))

    {r, g, b} =
      cond do
        section < 1 -> {chroma, x, 0.0}
        section < 2 -> {x, chroma, 0.0}
        section < 3 -> {0.0, chroma, x}
        section < 4 -> {0.0, x, chroma}
        section < 5 -> {x, 0.0, chroma}
        true -> {chroma, 0.0, x}
      end

    match = lightness - chroma / 2
    {r + match, g + match, b + match}
  end

  defp composite({r, g, b, alpha}, {br, bg, bb, _}) do
    {r * alpha + br * (1 - alpha), g * alpha + bg * (1 - alpha), b * alpha + bb * (1 - alpha),
     1.0}
  end

  defp luminance({r, g, b, _}) do
    0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  end

  defp linear(channel) when channel <= 0.04045, do: channel / 12.92
  defp linear(channel), do: :math.pow((channel + 0.055) / 1.055, 2.4)

  defp clamp(number), do: min(1.0, max(0.0, number))
end
