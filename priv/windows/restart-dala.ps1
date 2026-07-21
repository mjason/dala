[CmdletBinding()]
param(
  [string]$TaskName = "Dala",
  [string]$StopExecutable,
  [switch]$StopOnly
)

$ErrorActionPreference = "Stop"

function Get-ReleaseBeamProcesses([string]$Executable) {
  if ([string]::IsNullOrWhiteSpace($Executable)) { return @() }

  $releaseRoot = Split-Path -Parent (Split-Path -Parent $Executable)
  if ([string]::IsNullOrWhiteSpace($releaseRoot)) { return @() }

  @(
    Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf($releaseRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
      }
  )
}

function Stop-DalaRelease([string]$Executable) {
  if ([string]::IsNullOrWhiteSpace($Executable) -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    return
  }

  & $Executable stop 2>$null | Out-Null

  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if ((Get-ReleaseBeamProcesses $Executable).Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }

  foreach ($process in Get-ReleaseBeamProcesses $Executable) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if ((Get-ReleaseBeamProcesses $Executable).Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }

  throw "Dala release did not stop: $Executable"
}

function Get-TaskLauncher([string]$ReleaseDir) {
  Get-ChildItem -LiteralPath $ReleaseDir -Filter "dala_task_launcher.exe" -Recurse -File |
    Where-Object { $_.FullName -like "*\priv\bin\dala_task_launcher.exe" } |
    Select-Object -First 1 -ExpandProperty FullName
}

function Set-CurrentTaskAction([string]$Executable, [string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Executable)) { return }

  $releaseDir = Split-Path -Parent (Split-Path -Parent $Executable)
  $versionsDir = Split-Path -Parent $releaseDir
  $installRoot = Split-Path -Parent $versionsDir
  $currentFile = Join-Path $installRoot "current.txt"
  if (-not (Test-Path -LiteralPath $currentFile -PathType Leaf)) {
    throw "Dala current version pointer is missing: $currentFile"
  }

  $tag = (Get-Content -LiteralPath $currentFile -Raw).Trim()
  if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "Invalid Dala version pointer: $tag"
  }

  $currentRelease = Join-Path $versionsDir $tag
  $launcher = Get-TaskLauncher $currentRelease
  if (-not $launcher) { throw "Release is missing priv\bin\dala_task_launcher.exe: $currentRelease" }

  $runner = Join-Path $installRoot "run-dala.ps1"
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Dala task runner is missing: $runner"
  }

  $logFile = Join-Path $installRoot "logs\server.log"
  $action = New-ScheduledTaskAction -Execute $launcher -Argument "`"$runner`" `"$logFile`""
  Set-ScheduledTask -TaskName $Name -Action $action | Out-Null
}

# The updater launches this helper from inside the server request. Give that
# response time to reach the browser before stopping the running release.
if (-not $StopOnly) { Start-Sleep -Milliseconds 750 }
Stop-DalaRelease $StopExecutable

if ($StopOnly) { exit 0 }

& schtasks.exe /End /TN $TaskName 2>$null | Out-Null
Start-Sleep -Milliseconds 250
Set-CurrentTaskAction $StopExecutable $TaskName
& schtasks.exe /Run /TN $TaskName | Out-Null
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
