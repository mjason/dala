defmodule Mix.Tasks.Compile.DalaHolder do
  @moduledoc """
  Builds the `dala_holder` PTY holder and the Windows Scheduled Task launcher
  (plain cargo binaries, not Rustler NIFs), then installs them under `priv/bin`.
  Skipped when the installed binaries are newer than every source file.
  """

  use Mix.Task.Compiler

  @crate "native/dala_holder"
  @windows? match?({:win32, _}, :os.type())
  @executables if(@windows?,
                 do: ["dala_holder.exe", "dala_task_launcher.exe"],
                 else: ["dala_holder"]
               )
  @targets Enum.map(@executables, &Path.join("priv/bin", &1))

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

      Enum.each(Enum.zip(@executables, @targets), fn {executable, target} ->
        File.mkdir_p!(Path.dirname(target))
        # Unlink first: overwriting a running binary fails on some platforms;
        # removing also leaves Unix holders on their existing image.
        _ = File.rm(target)
        File.cp!(Path.join([@crate, "target", "release", executable]), target)
      end)
    end

    {:ok, []}
  end

  defp stale? do
    sources = [Path.join(@crate, "Cargo.toml") | Path.wildcard(Path.join(@crate, "src/**/*.rs"))]

    Enum.any?(@targets, fn target ->
      case File.stat(target, time: :posix) do
        {:error, _reason} ->
          true

        {:ok, %{mtime: built_at}} ->
          Enum.any?(sources, fn source ->
            case File.stat(source, time: :posix) do
              {:ok, %{mtime: changed_at}} -> changed_at > built_at
              {:error, _reason} -> false
            end
          end)
      end
    end)
  end
end
