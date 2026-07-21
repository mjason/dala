defmodule Dala.Terminal.ShellTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.Shell

  test "Windows cmd paths receive interactive cmd options" do
    assert Shell.spawn_options(~S(C:\Windows\System32\cmd.exe), {:win32, :nt}) == [
             args: ["/D", "/Q", "/K", "rem"],
             env: [{"PROMPT", "$E]7;file://localhost/$P$E\\$P$G"}]
           ]
  end

  test "Windows PowerShell paths receive the integration bootstrap" do
    [args: args, env: []] =
      Shell.spawn_options(~S(C:\Program Files\PowerShell\7\pwsh.exe), {:win32, :nt})

    assert ["-NoExit", "-Command", command] = args
    assert command =~ "dala-powershell.ps1"
  end

  test "Windows executable paths use native separators before CreateProcess" do
    assert Shell.normalize_executable("c:/Windows/System32/cmd.exe", {:win32, :nt}) ==
             ~S(c:\Windows\System32\cmd.exe)

    assert Shell.normalize_executable("/bin/bash", {:unix, :linux}) == "/bin/bash"
  end
end
