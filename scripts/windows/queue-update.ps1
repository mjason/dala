[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$HelperPath,
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,
  [Parameter(Mandatory = $true)]
  [string]$TaskName
)

$ErrorActionPreference = "Stop"
$HelperPath = [System.IO.Path]::GetFullPath($HelperPath)
$RequestPath = [System.IO.Path]::GetFullPath($RequestPath)

if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
  throw "Update helper is missing: $HelperPath"
}
if (-not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) {
  throw "Update request is missing: $RequestPath"
}
if ($TaskName -notmatch '^[0-9A-Za-z _.()-]+$') {
  throw "Invalid update task name: $TaskName"
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
  if ($existing.State -eq "Running") { throw "Update task '$TaskName' is already running" }
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$arguments = @(
  "-NoProfile",
  "-NonInteractive",
  "-ExecutionPolicy Bypass",
  "-File `"$HelperPath`"",
  "-RequestPath `"$RequestPath`"",
  "-HelperTaskName `"$TaskName`""
) -join " "
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

try {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
    -Settings $settings -Description "Dala update helper" -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
} catch {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  throw
}

Write-Output "Queued Dala update using scheduled task '$TaskName'"
