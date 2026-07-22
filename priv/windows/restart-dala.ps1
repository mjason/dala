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
  try {
    $releaseDir = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $DalaExecutable))).TrimEnd([char[]]"\/")
    $tag = Split-Path -Leaf $releaseDir
    if ($tag -cnotmatch $TagPattern) { return $null }
    $version = $tag.Substring(1)
    $expectedDalaExecutable = Join-Path $releaseDir "bin\dala.bat"
    if (-not (Test-SamePath $DalaExecutable $expectedDalaExecutable)) { return $null }
    $tokens = @((Get-Content -LiteralPath (Join-Path $releaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
    if ($tokens.Count -ne 2 -or [string]$tokens[1] -cne $version) { return $null }
    $erts = [string]$tokens[0]
    if ($erts -notmatch '^[0-9A-Za-z._-]+$') { return $null }
    $expected = Join-Path $releaseDir "erts-$erts\bin\erl.exe"
    [pscustomobject]@{
      Executable = [IO.Path]::GetFullPath($expected)
      Boot = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start"))
      BootFile = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start.boot"))
    }
  } catch {
    $null
  }
}

function Get-ReleaseBeamProcesses([string]$Executable) {
  $identity = Get-ReleaseIdentity $Executable
  if (-not $identity) { return @() }
  @(
    Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $processExecutable = [string]$_.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($processExecutable) -or
            -not (Test-SamePath $processExecutable $identity.Executable)) { return $false }
        $command = ([string]$_.CommandLine).Replace('/', '\').Replace('"', '')
        foreach ($boot in @($identity.Boot, $identity.BootFile)) {
          $index = $command.IndexOf($boot, [StringComparison]::OrdinalIgnoreCase)
          if ($index -ge 0) {
            $prefix = $command.Substring(0, $index).TrimEnd()
            if ($prefix.EndsWith("-boot", [StringComparison]::OrdinalIgnoreCase) -or
                $prefix.EndsWith("-boot=", [StringComparison]::OrdinalIgnoreCase) -or
                $prefix.EndsWith("--boot", [StringComparison]::OrdinalIgnoreCase) -or
                $prefix.EndsWith("--boot=", [StringComparison]::OrdinalIgnoreCase)) { return $true }
          }
        }
        $false
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
  Set-ScheduledTask -TaskName $Name -TaskPath "\" -Action $action | Out-Null
}

function Get-DalaTask([string]$Name) {
  $tasks = @(Get-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction SilentlyContinue)
  if ($tasks.Count -gt 1) { throw "Multiple root Scheduled Tasks match '$Name'" }
  if ($tasks.Count -eq 0) { return $null }
  $tasks[0]
}

function End-DalaTask([string]$Name) {
  $task = Get-DalaTask $Name
  if (-not $task) { throw "Dala Scheduled Task is missing: $Name" }

  # schtasks /End returns an error for an already-idle task.  Only invoke it
  # when the scheduler reports Running, then verify that the stop completed
  # before changing the action underneath the scheduler.
  if ([string]$task.State -ceq "Running") {
    & schtasks.exe /End /TN "\$Name" 2>$null | Out-Null
    $endStatus = $LASTEXITCODE
    if ($endStatus -ne 0) {
      throw "Could not stop Scheduled Task '$Name' (schtasks /End exit $endStatus)"
    }

    for ($attempt = 0; $attempt -lt 50; $attempt++) {
      $current = Get-DalaTask $Name
      if (-not $current -or [string]$current.State -cne "Running") { return }
      Start-Sleep -Milliseconds 100
    }
    throw "Scheduled Task '$Name' remained Running after schtasks /End"
  }
}

# The updater launches this helper from inside the server request. Give that
# response time to reach the browser before stopping the running release.
Assert-TaskName $TaskName
if (-not $StopOnly) { Start-Sleep -Milliseconds 750 }
Stop-DalaRelease $StopExecutable

if ($StopOnly) { exit 0 }

End-DalaTask $TaskName
Set-CurrentTaskAction $StopExecutable $TaskName
& schtasks.exe /Run /TN "\$TaskName" | Out-Null
$runStatus = $LASTEXITCODE
if ($runStatus -ne 0) {
  throw "Could not start Scheduled Task '$TaskName' (schtasks /Run exit $runStatus)"
}
