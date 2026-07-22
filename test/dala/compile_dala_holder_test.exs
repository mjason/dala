defmodule Mix.Tasks.Compile.DalaHolderTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Compile.DalaHolder

  test "tracks Cargo lockfiles and build configuration as native inputs" do
    inputs = DalaHolder.cargo_inputs()

    assert Path.join("native/dala_holder", "Cargo.toml") in inputs
    assert Path.join("native/dala_holder", "Cargo.lock") in inputs
    assert Path.join("native/dala_holder", "build.rs") in inputs
    assert Path.join("native/dala_holder", ".cargo/config.toml") in inputs
  end

  test "rebuilds when Cargo.lock changes even if Rust sources do not" do
    root = temporary_root()
    target = Path.join(root, "dala_holder")
    lockfile = Path.join(root, "Cargo.lock")

    File.write!(target, "binary")
    File.write!(lockfile, "lock")
    File.touch(target, {{2020, 1, 1}, {0, 0, 0}})
    File.touch(lockfile, {{2020, 1, 2}, {0, 0, 0}})

    assert DalaHolder.stale?([target], [lockfile])

    File.touch(lockfile, {{2019, 12, 31}, {0, 0, 0}})
    refute DalaHolder.stale?([target], [lockfile])
  end

  test "notices a newly added optional Cargo build script" do
    root = temporary_root()
    target = Path.join(root, "dala_holder")
    build_script = Path.join(root, "build.rs")

    File.write!(target, "binary")
    File.touch(target, {{2020, 1, 2}, {0, 0, 0}})

    refute DalaHolder.stale?([target], [build_script])

    File.write!(build_script, "fn main() {}")
    File.touch(build_script, {{2020, 1, 3}, {0, 0, 0}})
    assert DalaHolder.stale?([target], [build_script])
  end

  test "a missing native target is stale" do
    root = temporary_root()
    refute File.exists?(Path.join(root, "dala_holder"))
    assert DalaHolder.stale?([Path.join(root, "dala_holder")], [])
  end

  test "removing a required Cargo manifest is stale" do
    root = temporary_root()
    target = Path.join(root, "dala_holder")
    manifest = Path.join(root, "Cargo.toml")

    File.write!(target, "binary")
    File.touch(target, {{2020, 1, 1}, {0, 0, 0}})
    refute File.exists?(manifest)

    assert DalaHolder.stale?([target], [manifest])
  end

  defp temporary_root do
    root = Path.join(System.tmp_dir!(), "dala-holder-stale-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
