[CmdletBinding()]
param(
  [string]$TaskName = "Dala",
  [string]$StopExecutable,
  [switch]$StopOnly
)

$ErrorActionPreference = "Stop"
$TagPattern = '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'

function Assert-TaskName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 238 -or
      $Name -match '[\\/:*?"<>|\[\]]' -or $Name -match '[\r\n]' -or $Name.Trim() -cne $Name) {
    throw "Invalid Scheduled Task name: $Name"
  }
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ReleaseIdentity([string]$DalaExecutable) {
  if ([string]::IsNullOrWhiteSpace($DalaExecutable)) { return $null }
  $releaseDir = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $DalaExecutable))).TrimEnd([char[]]"\/")
  $tag = Split-Path -Leaf $releaseDir
  if ($tag -cnotmatch $TagPattern) {
    throw "Cannot inspect Dala release with an invalid version directory: $releaseDir"
  }
  $version = $tag.Substring(1)
  $expectedDalaExecutable = Join-Path $releaseDir "bin\dala.bat"
  if (-not (Test-SamePath $DalaExecutable $expectedDalaExecutable)) {
    throw "Dala executable is outside its release layout: $DalaExecutable"
  }
  $tokens = @((Get-Content -LiteralPath (Join-Path $releaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
  if ($tokens.Count -ne 2 -or [string]$tokens[1] -cne $version) {
    throw "Cannot inspect Dala release with malformed start_erl.data: $releaseDir"
  }
  $erts = [string]$tokens[0]
  if ($erts -notmatch '^[0-9A-Za-z._-]+$') {
    throw "Cannot inspect Dala release with invalid ERTS version: $releaseDir"
  }
  $expected = Join-Path $releaseDir "erts-$erts\bin\erl.exe"
  [pscustomobject]@{
    Executable = [IO.Path]::GetFullPath($expected)
    Boot = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start"))
    BootFile = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start.boot"))
  }
}

function Test-ReleaseBootCommand([string]$CommandLine, [string[]]$BootCandidates) {
  $command = $CommandLine.Replace('/', '\')
  foreach ($boot in $BootCandidates) {
    $normalizedBoot = ([string]$boot).Replace('/', '\')
    $escapedBoot = [regex]::Escape($normalizedBoot)
    $pattern = '(?:^|\s)--?boot(?:=|\s+)(?:"' + $escapedBoot + '"|' + $escapedBoot + ')(?=\s|$)'
    if ([regex]::IsMatch($command, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      return $true
    }
  }
  $false
}

function Get-ReleaseBeamProcesses([string]$Executable) {
  $identity = Get-ReleaseIdentity $Executable
  if (-not $identity) { return @() }
  $releaseProcesses = @()
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction Stop)) {
    if ($null -eq $process) {
      throw "Cannot determine the identity of an erl.exe process; refusing to continue"
    }

    $processExecutable = [string]$process.ExecutablePath
    $processCommandLine = [string]$process.CommandLine
    if ([string]::IsNullOrWhiteSpace($processExecutable) -or
        [string]::IsNullOrWhiteSpace($processCommandLine)) {
      throw "Cannot determine the identity of an erl.exe process; refusing to continue"
    }
    if (-not (Test-SamePath $processExecutable $identity.Executable)) { continue }

    if (-not (Test-ReleaseBootCommand $processCommandLine @($identity.Boot, $identity.BootFile))) {
      throw "Cannot confirm the Dala release identity of erl.exe at $processExecutable; refusing to continue"
    }
    if ($null -eq $process.PSObject.Properties["ProcessId"] -or
        [string]::IsNullOrWhiteSpace([string]$process.ProcessId)) {
      throw "Cannot determine the process id of an erl.exe process; refusing to continue"
    }
    $releaseProcesses += $process
  }
  $releaseProcesses
}

function Stop-DalaRelease([string]$Executable) {
  if ([string]::IsNullOrWhiteSpace($Executable)) {
    throw "Cannot stop Dala release: executable path is empty"
  }
  try {
    $executableExists = Test-Path -LiteralPath $Executable -PathType Leaf -ErrorAction Stop
  } catch {
    throw "Cannot inspect Dala release executable '$Executable': $($_.Exception.Message)"
  }
  if (-not $executableExists) {
    throw "Cannot stop Dala release: executable is missing or not a regular file: $Executable"
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

function Get-TaskLauncher([string]$ReleaseDir, [string]$Version) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    $tag = Split-Path -Leaf ([IO.Path]::GetFullPath($ReleaseDir).TrimEnd([char[]]"\/"))
    if ($tag -cnotmatch $TagPattern) { return $null }
    $Version = $tag.Substring(1)
  }
  if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { return $null }
  $launcher = Join-Path $ReleaseDir "lib\dala-$Version\priv\bin\dala_task_launcher.exe"
  if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { return $null }
  try {
    if (([IO.File]::GetAttributes($launcher) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
  } catch {
    return $null
  }
  [IO.Path]::GetFullPath($launcher)
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
  if ($tag -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "Invalid Dala version pointer: $tag"
  }

  $currentRelease = Join-Path $versionsDir $tag
  $launcher = Get-TaskLauncher $currentRelease $tag.Substring(1)
  if (-not $launcher) { throw "Release is missing priv\bin\dala_task_launcher.exe: $currentRelease" }

  $runner = Join-Path $installRoot "run-dala.ps1"
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Dala task runner is missing: $runner"
  }

  $logFile = Join-Path $installRoot "logs\server.log"
  $action = New-ScheduledTaskAction -Execute $launcher -Argument "`"$runner`" `"$logFile`""
  Set-DalaTaskActionVerified $Name $action
}

function Get-DalaTaskExact([string]$Name) {
  $tasks = @(
    Get-ScheduledTask -TaskPath "\" -ErrorAction Stop |
      Where-Object { [string]$_.TaskName -ceq $Name }
  )
  if ($tasks.Count -gt 1) { throw "Multiple root Scheduled Tasks match '$Name'" }
  if ($tasks.Count -eq 0) { return $null }
  $tasks[0]
}

function Assert-DalaTaskPrincipal($Task) {
  $expectedSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $userId = [string]$Task.Principal.UserId
  try {
    $actualSid = if ($userId -match '^S-[0-9-]+$') {
      [Security.Principal.SecurityIdentifier]::new($userId).Value
    } else {
      ([Security.Principal.NTAccount]::new($userId)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
  } catch {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }

  if ($actualSid -cne $expectedSid -or
      [string]$Task.Principal.LogonType -cne "Interactive" -or
      [string]$Task.Principal.RunLevel -cne "Limited") {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }
}

function Assert-DalaTaskOwnership($Task, [string]$InstallRoot) {
  if (-not $Task) { throw "Dala Scheduled Task is missing: $TaskName" }
  Assert-DalaTaskPrincipal $Task

  $root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]]"\/")
  $runner = Join-Path $root "run-dala.ps1"
  $logFile = Join-Path $root "logs\server.log"
  $expectedArguments = "`"$runner`" `"$logFile`""
  $actions = @($Task.Actions)
  if ($actions.Count -ne 1 -or [string]$actions[0].Arguments -cne $expectedArguments) {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }

  $versionsRoot = Join-Path $root "versions"
  $ownedLaunchers = @()
  foreach ($directory in @(Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction Stop)) {
    if ($directory.Name -cmatch $TagPattern) {
      $launcher = Get-TaskLauncher $directory.FullName
      if ($launcher) { $ownedLaunchers += $launcher }
    }
  }
  if (-not ($ownedLaunchers | Where-Object { Test-SamePath ([string]$actions[0].Execute) $_ })) {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }
}

function Test-DalaTaskAction($Task, $ExpectedAction) {
  $actions = @($Task.Actions)
  if ($actions.Count -ne 1) { return $false }
  try {
    (Test-SamePath ([string]$actions[0].Execute) ([string]$ExpectedAction.Execute)) -and
      [string]$actions[0].Arguments -ceq [string]$ExpectedAction.Arguments
  } catch {
    $false
  }
}

function Set-DalaTaskActionVerified([string]$Name, $Action) {
  $task = Get-DalaTaskExact $Name
  if (-not $task) { throw "Dala Scheduled Task is missing: $Name" }

  $setError = $null
  try {
    Set-ScheduledTask -TaskName $Name -TaskPath "\" -Action $Action -ErrorAction Stop | Out-Null
  } catch {
    $setError = $_.Exception.Message
  }

  try {
    $task = Get-DalaTaskExact $Name
  } catch {
    if ($setError) {
      throw "$setError; could not verify Scheduled Task action for '$Name': $($_.Exception.Message)"
    }
    throw
  }
  if (-not $task) {
    $message = "Dala Scheduled Task disappeared while updating its action: $Name"
    if ($setError) { $message = "$setError; $message" }
    throw $message
  }
  if (Test-DalaTaskAction $task $Action) {
    if ($setError) {
      Write-Warning "Scheduled Task action update reported an error after '$Name' was updated: $setError" `
        -WarningAction Continue
    }
    return
  }
  if ($setError) { throw "$setError; Scheduled Task '$Name' still has the previous action" }
  throw "Scheduled Task '$Name' action did not match after Set-ScheduledTask returned"
}

function Stop-DalaTaskVerified([string]$Name) {
  $task = Get-DalaTaskExact $Name
  if (-not $task) { throw "Dala Scheduled Task is missing: $Name" }
  if ([string]$task.State -notin @("Running", "Queued")) { return }

  $stopError = $null
  try {
    Stop-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction Stop
  } catch {
    $stopError = $_.Exception.Message
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    $task = Get-DalaTaskExact $Name
    if (-not $task) {
      $message = "Dala Scheduled Task disappeared while stopping: $Name"
      if ($stopError) { $message = "$stopError; $message" }
      throw $message
    }
    if ([string]$task.State -notin @("Running", "Queued")) { break }
    Start-Sleep -Milliseconds 100
  }
  if ([string]$task.State -in @("Running", "Queued")) {
    $message = "Scheduled Task '$Name' remained active after stop"
    if ($stopError) { $message = "$stopError; $message" }
    throw $message
  }
  if ($stopError) {
    Write-Warning "Scheduled Task stop reported an error after '$Name' stopped: $stopError" `
      -WarningAction Continue
  }
}

function Start-DalaTaskVerified([string]$Name) {
  $task = Get-DalaTaskExact $Name
  if (-not $task) { throw "Dala Scheduled Task is missing: $Name" }
  if ([string]$task.State -in @("Running", "Queued")) { return }

  $startError = $null
  try {
    Start-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction Stop
  } catch {
    $startError = $_.Exception.Message
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    $task = Get-DalaTaskExact $Name
    if (-not $task) {
      $message = "Dala Scheduled Task disappeared while starting: $Name"
      if ($startError) { $message = "$startError; $message" }
      throw $message
    }
    if ([string]$task.State -in @("Running", "Queued")) { break }
    Start-Sleep -Milliseconds 100
  }
  if ([string]$task.State -notin @("Running", "Queued")) {
    $message = "Scheduled Task '$Name' did not become active after start"
    if ($startError) { $message = "$startError; $message" }
    throw $message
  }
  if ($startError) {
    Write-Warning "Scheduled Task start reported an error after '$Name' started: $startError" `
      -WarningAction Continue
  }
}

function Restart-DalaTask([string]$Executable, [string]$Name, [bool]$OnlyStop) {
  if (-not $OnlyStop) {
    $releaseDir = Split-Path -Parent (Split-Path -Parent $Executable)
    $installRoot = Split-Path -Parent (Split-Path -Parent $releaseDir)
    $task = Get-DalaTaskExact $Name
    Assert-DalaTaskOwnership $task $installRoot
  }
  Stop-DalaRelease $Executable
  if ($OnlyStop) { return }

  Stop-DalaTaskVerified $Name
  Set-CurrentTaskAction $Executable $Name
  Start-DalaTaskVerified $Name
}

# The updater launches this helper from inside the server request. Give that
# response time to reach the browser before stopping the running release.
Assert-TaskName $TaskName
if (-not $StopOnly) { Start-Sleep -Milliseconds 750 }
Restart-DalaTask $StopExecutable $TaskName ([bool]$StopOnly)
