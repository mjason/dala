Option Explicit

Dim shell, fileSystem, launcher, command, argumentIndex, quote
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
quote = Chr(34)

launcher = fileSystem.BuildPath(fileSystem.GetParentFolderName(WScript.ScriptFullName), "launcher.cmd")
command = quote & shell.ExpandEnvironmentStrings("%ComSpec%") & quote & " /d /c " & quote & quote & launcher & quote

For argumentIndex = 0 To WScript.Arguments.Count - 1
  command = command & " " & quote & Replace(WScript.Arguments(argumentIndex), quote, quote & quote) & quote
Next

command = command & quote
WScript.Quit shell.Run(command, 0, True)
