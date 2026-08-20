[CmdletBinding()]
param(
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "Dala"),
  [Alias("ServiceName")]
  [string]$TaskName = "Dala"
)

$ErrorActionPreference = "Stop"
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$currentFile = Join-Path $InstallRoot "current.txt"
$updateTaskName = "$TaskName-Update"

$updateTask = Get-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue
if ($null -ne $updateTask) {
  Stop-ScheduledTask -TaskName $updateTaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $updateTaskName -Confirm:$false
}

if (Test-Path -LiteralPath $currentFile) {
  $version = (Get-Content -LiteralPath $currentFile -Raw).Trim()
  $entrypoint = Join-Path $InstallRoot "versions\$version\bin\dala.bat"
  if (Test-Path -LiteralPath $entrypoint) {
    & {
      $ErrorActionPreference = "SilentlyContinue"
      & $entrypoint stop 2>&1 | Write-Verbose
    }
  }
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $task) {
  Write-Output "Scheduled task '$TaskName' is not installed"
  exit 0
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Output "Removed scheduled task '$TaskName'; releases and user data were preserved"
