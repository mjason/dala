defmodule Mix.Tasks.Compile.DalaHolder do
  @moduledoc """
  Builds the `dala_holder` PTY holder binary (a plain cargo binary, not a
  Rustler NIF) and installs it at `priv/bin/dala_holder`. Skipped when the
  installed binary is newer than every source file.
  """

  use Mix.Task.Compiler

  @crate "native/dala_holder"
  @target "priv/bin/dala_holder"

  @impl true
  def run(_args) do
    if stale?() do
      Mix.shell().info("Compiling dala_holder (cargo)")

      {output, status} =
        System.cmd("cargo", ["build", "--release"],
          cd: @crate,
          stderr_to_stdout: true,
          env: [{"CARGO_TERM_COLOR", "never"}]
        )

      if status != 0 do
        Mix.raise("cargo build for dala_holder failed:\n#{output}")
      end

      File.mkdir_p!(Path.dirname(@target))
      File.cp!(Path.join(@crate, "target/release/dala_holder"), @target)
    end

    {:ok, []}
  end

  defp stale? do
    case File.stat(@target, time: :posix) do
      {:error, _reason} ->
        true

      {:ok, %{mtime: built_at}} ->
        [Path.join(@crate, "Cargo.toml") | Path.wildcard(Path.join(@crate, "src/**/*.rs"))]
        |> Enum.any?(fn source ->
          case File.stat(source, time: :posix) do
            {:ok, %{mtime: changed_at}} -> changed_at > built_at
            {:error, _reason} -> false
          end
        end)
    end
  end
end
