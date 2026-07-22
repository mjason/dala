defmodule Dala.Updater.UnixScriptTest do
  use ExUnit.Case, async: true

  @moduletag skip: Dala.TestPlatform.windows?()

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "dala-unix-script-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    install_fake_commands(bin, root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, bin: bin}
  end

  test "install aborts when the release checksum cannot be downloaded", context do
    {output, status} = run_script(context, "install.sh", "v9.9.9")

    assert status != 0
    assert output =~ "could not download checksum"
    refute File.exists?(Path.join(context.root, "versions/v9.9.9"))
    refute File.exists?(Path.join(context.root, "tar-called"))
  end

  test "update aborts before unpacking when the release checksum is unavailable", context do
    current = Path.join(context.root, "versions/v1.0.0/bin/dala")
    File.mkdir_p!(Path.dirname(current))
    File.write!(current, "#!/bin/sh\n")
    File.chmod!(current, 0o700)
    File.ln_s!(Path.join(context.root, "versions/v1.0.0"), Path.join(context.root, "current"))

    {output, status} = run_script(context, "update.sh", "v9.9.9")

    assert status != 0
    assert output =~ "could not download checksum"
    assert current_tag(context.root) == "v1.0.0"
    refute File.exists?(Path.join(context.root, "versions/v9.9.9"))
    refute File.exists?(Path.join(context.root, "tar-called"))
    refute File.exists?(Path.join(context.root, "service-called"))
  end

  defp run_script(context, script, tag) do
    path = Path.expand("../../../#{script}", __DIR__)

    System.cmd(
      "bash",
      [path, tag],
      env: [
        {"PATH", context.bin <> ":" <> System.get_env("PATH", "")},
        {"HOME", Path.join(context.root, "home")},
        {"USER", "dala-test"},
        {"DALA_HOME", context.root},
        {"DALA_DATA_DIR", Path.join(context.root, "data")},
        {"XDG_CONFIG_HOME", Path.join(context.root, "config")},
        {"DALA_TEST_ROOT", context.root},
        {"DALA_TEST_TAR_MARKER", Path.join(context.root, "tar-called")},
        {"DALA_TEST_SERVICE_MARKER", Path.join(context.root, "service-called")}
      ],
      stderr_to_stdout: true
    )
  end

  defp current_tag(root) do
    root |> Path.join("current") |> File.read_link!() |> Path.basename()
  end

  defp install_fake_commands(bin, root) do
    write_executable(Path.join(bin, "uname"), """
    #!/bin/sh
    case "$1" in
      -s) printf 'Linux\\n' ;;
      -m) printf 'x86_64\\n' ;;
      *) exit 1 ;;
    esac
    """)

    write_executable(Path.join(bin, "curl"), """
    #!/bin/sh
    set -eu
    output=''
    url=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o)
          output=$2
          shift 2
          ;;
        *)
          url=$1
          shift
          ;;
      esac
    done
    case "$url" in
      *.sha256) exit 22 ;;
      *) printf 'not-a-real-release' > "$output" ;;
    esac
    """)

    write_executable(Path.join(bin, "tar"), """
    #!/bin/sh
    : > "$DALA_TEST_TAR_MARKER"
    exit 0
    """)

    write_executable(Path.join(bin, "systemctl"), """
    #!/bin/sh
    : > "$DALA_TEST_SERVICE_MARKER"
    exit 0
    """)

    write_executable(Path.join(bin, "loginctl"), """
    #!/bin/sh
    exit 0
    """)

    File.mkdir_p!(root)
  end

  defp write_executable(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o700)
  end
end
