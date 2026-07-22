defmodule Dala.TestCoverage do
  @moduledoc false

  @excluded_beams [
    "Elixir.Dala.Git.beam",
    "Elixir.Dala.ThemeRenderer.beam",
    "Elixir.Dala.TestCoverage.beam"
  ]

  def start(compile_path, opts) do
    hidden_beams = hide_excluded_beams(compile_path)

    try do
      Mix.Tasks.Test.Coverage.start(compile_path, opts)
    after
      restore_excluded_beams(hidden_beams)
    end
  end

  defp hide_excluded_beams(compile_path) do
    @excluded_beams
    |> Enum.map(&Path.join(compile_path, &1))
    |> Enum.filter(&File.exists?/1)
    |> Enum.map(fn beam_path ->
      hidden_path = beam_path <> ".coverage-excluded"
      File.rename!(beam_path, hidden_path)
      {beam_path, hidden_path}
    end)
  end

  defp restore_excluded_beams(hidden_beams) do
    Enum.each(hidden_beams, fn {beam_path, hidden_path} ->
      File.rename!(hidden_path, beam_path)
    end)
  end
end
