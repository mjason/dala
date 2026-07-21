$ErrorActionPreference = "Stop"

$Root = if ($env:DALA_HOME) { $env:DALA_HOME } else { Join-Path $env:LOCALAPPDATA "Dala" }
$ConfigFile = if ($env:DALA_CONFIG) { $env:DALA_CONFIG } else { Join-Path $env:APPDATA "Dala\dala.env" }

Get-Content -LiteralPath $ConfigFile | ForEach-Object {
  $line = $_.Trim()
  if ($line -and -not $line.StartsWith("#")) {
    $parts = $line.Split("=", 2)
    if ($parts.Count -eq 2) {
      [Environment]::SetEnvironmentVariable($parts[0], $parts[1], "Process")
    }
  }
}

$tag = (Get-Content -LiteralPath (Join-Path $Root "current.txt") -Raw).Trim()
if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
  throw "Invalid Dala version pointer: $tag"
}

$dala = Join-Path $Root "versions\$tag\bin\dala.bat"
if (-not (Test-Path -LiteralPath $dala -PathType Leaf)) {
  throw "Dala release executable is missing: $dala"
}

function Invoke-Dala([ValidateSet("eval", "start")][string]$Command, [string]$Expression) {
  $commandLine = '""' + $dala + '" ' + $Command
  if (-not [string]::IsNullOrEmpty($Expression)) {
    $commandLine += ' "' + $Expression + '"'
  }
  $commandLine += '"'

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
  $startInfo.Arguments = "/d /s /c $commandLine"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WorkingDirectory = Split-Path -Parent $dala

  $process = [Diagnostics.Process]::Start($startInfo)
  $process.WaitForExit()
  $exitCode = $process.ExitCode
  $process.Dispose()
  $exitCode
}

$migrateStatus = Invoke-Dala "eval" "Dala.Release.migrate()"
if ($migrateStatus -ne 0) { exit $migrateStatus }

exit (Invoke-Dala "start")
