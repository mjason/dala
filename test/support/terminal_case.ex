defmodule Dala.TerminalCase do
  @moduledoc """
  Case template for tests that drive a real terminal session.

  A session owns an out-of-process holder and the files it leaves behind, so
  the cleanup contract belongs in one place: every new holder-side artifact
  would otherwise have to be remembered in each test file, and the copies had
  already drifted apart on that exact point.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Dala.TerminalCase

      alias Dala.Terminal.{Holder, Server}

      @moduletag :terminal
    end
  end

  setup tags do
    Dala.DataCase.setup_sandbox(tags)
    :ok
  end

  alias Dala.Terminal.{Holder, Server}

  @doc """
  Creates a running session and tears it down — shell, holder and the holder's
  exit/final/text/log files — when the test ends.
  """
  def create_session!(attrs \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: shell()}, attrs))

    ExUnit.Callbacks.on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      id = to_string(session.id)
      stop_holder(id)
      File.rm(Holder.socket_path(id))
      File.rm(Holder.token_path(id))
      File.rm(Holder.exit_path(id))
      File.rm(Holder.final_path(id))
      File.rm(Holder.text_final_path(id))
      File.rm(Holder.socket_path(id) <> ".log")
    end)

    session
  end

  @doc "Bash executable used by cross-platform PTY integration tests."
  def shell do
    case :os.type() do
      {:win32, :nt} -> git_bash!()
      _ -> System.get_env("SHELL") || "/bin/bash"
    end
  end

  @doc "Converts an absolute path to the syntax understood by the test Bash."
  def shell_path(path) do
    normalized = Dala.Paths.expand_user(path)

    case {Dala.Platform.windows?(), normalized} do
      {true, <<drive, ":/", rest::binary>>} ->
        "/#{String.downcase(<<drive>>)}" <> if(rest == "", do: "", else: "/#{rest}")

      _ ->
        normalized
    end
  end

  @doc """
  Polls `fun` until it returns true. Prefer the labelled form: a bare
  "condition never became true" says nothing when a test polls four different
  things before failing.
  """
  def eventually(fun) when is_function(fun, 0), do: eventually("condition", fun, 200)

  def eventually(label, fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> ExUnit.Assertions.flunk("never became true: #{label}")
      true -> (Process.sleep(20) || :ok) && eventually(label, fun, attempts - 1)
    end
  end

  @doc "Whether the session's retained output window contains `needle`."
  def seen?(pid, needle), do: String.contains?(retained_output(pid), needle)

  @doc "The raw bytes currently retained by the session server, oldest first."
  def retained_output(pid) do
    :sys.get_state(pid).recent_output
    |> Enum.reverse()
    |> Enum.map_join(fn {_seq, data} -> data end)
  end

  @doc "The Windows holder process listening for `id`, or nil on other platforms."
  def holder_os_pid(id) do
    if Dala.Platform.windows?() do
      with {:ok, endpoint} <- Holder.socket_path(to_string(id)) |> File.read(),
           [_host, port] <- String.split(String.trim(endpoint), ":", parts: 2),
           {netstat, 0} <- System.cmd("netstat.exe", ["-ano", "-p", "tcp"]) do
        netstat
        |> String.split(["\r\n", "\n"], trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line) do
            [_protocol, local, _remote, "LISTENING", process_id] ->
              if String.ends_with?(local, ":" <> port), do: String.to_integer(process_id)

            _other ->
              nil
          end
        end)
      else
        _other -> nil
      end
    end
  end

  defp stop_holder(id) do
    case Holder.connect(id) do
      {:ok, socket} ->
        _ = Holder.send_kill(socket)
        :gen_tcp.close(socket)
        wait_holder_stopped(id, 50)

      {:error, _reason} ->
        :ok
    end

    # A saturated Windows holder can stop accepting TCP before its process
    # exits. The protocol cleanup above cannot reach that state, so use the
    # listening PID as a final test-only cleanup boundary.
    if Dala.Platform.windows?() and File.exists?(Holder.socket_path(id)) do
      case holder_os_pid(id) do
        pid when is_integer(pid) -> Dala.Platform.kill_process_tree(pid)
        _ -> :ok
      end
    end
  end

  defp wait_holder_stopped(_id, 0), do: :ok

  defp wait_holder_stopped(id, attempts) do
    case Holder.connect(id) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(20)
        wait_holder_stopped(id, attempts - 1)

      {:error, _reason} ->
        :ok
    end
  end

  defp git_bash! do
    git_root =
      case System.find_executable("git") do
        nil -> nil
        git -> git |> Path.dirname() |> Path.dirname()
      end

    candidates = [
      git_root && Path.join(git_root, "bin/bash.exe"),
      Path.join(System.get_env("ProgramFiles", "C:/Program Files"), "Git/bin/bash.exe")
    ]

    Enum.find(candidates, &(is_binary(&1) and File.regular?(&1))) ||
      raise "Git for Windows bash.exe is required for terminal integration tests"
  end
end
