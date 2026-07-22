defmodule Mix.Tasks.Compile.DalaHolder do
  @moduledoc """
  Builds the `dala_holder` PTY holder and the Windows Scheduled Task launcher
  (plain cargo binaries, not Rustler NIFs), then installs them under `priv/bin`.
  Skipped when the installed binaries are newer than every Cargo input.
  """

  use Mix.Task.Compiler

  @crate "native/dala_holder"
  @windows? match?({:win32, _}, :os.type())
  @executables if(@windows?,
                 do: ["dala_holder.exe", "dala_task_launcher.exe"],
                 else: ["dala_holder"]
               )
  @targets Enum.map(@executables, &Path.join("priv/bin", &1))
  @required_cargo_inputs ["Cargo.toml", "Cargo.lock"]

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

  @doc false
  def cargo_inputs do
    required = @required_cargo_inputs

    optional =
      ["build.rs", ".cargo/config", ".cargo/config.toml"] ++
        Path.wildcard(Path.join(@crate, ".cargo/**/*"))

    (required ++ optional)
    |> Enum.map(&Path.join(@crate, &1))
    |> Kernel.++(Path.wildcard(Path.join(@crate, "src/**/*.rs")))
    |> Enum.uniq()
  end

  @doc false
  def stale?(targets \\ @targets)

  def stale?(targets) when is_list(targets), do: stale?(targets, cargo_inputs())

  @doc false
  def stale?(targets, sources) when is_list(targets) and is_list(sources) do
    Enum.any?(targets, fn target ->
      case File.stat(target, time: :posix) do
        {:error, _reason} ->
          true

        {:ok, %{mtime: built_at}} ->
          Enum.any?(sources, fn source ->
            case File.stat(source, time: :posix) do
              {:ok, %{mtime: changed_at}} -> changed_at > built_at
              # Removing a required Cargo input changes the build contract
              # and must force a fresh build. Optional paths are retained by
              # cargo_inputs/0 so a newly added build script/config is
              # detected; a missing optional path is benign.
              {:error, :enoent} -> Path.basename(source) in @required_cargo_inputs
              {:error, _reason} -> false
            end
          end)
      end
    end)
  end
end
