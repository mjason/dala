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
    session = Dala.Terminal.create_session!(Map.merge(%{shell: "/bin/bash"}, attrs))

    ExUnit.Callbacks.on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      id = to_string(session.id)
      File.rm(Holder.exit_path(id))
      File.rm(Holder.final_path(id))
      File.rm(Holder.text_final_path(id))
      File.rm(Holder.socket_path(id) <> ".log")
    end)

    session
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
end
