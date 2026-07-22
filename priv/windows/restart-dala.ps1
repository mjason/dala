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
  $expectedEpmd = Join-Path $releaseDir "erts-$erts\bin\epmd.exe"
  [pscustomobject]@{
    Executable = [IO.Path]::GetFullPath($expected)
    Epmd = [IO.Path]::GetFullPath($expectedEpmd)
    Boot = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start"))
    BootFile = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start.boot"))
    CleanBoot = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start_clean"))
    CleanBootFile = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start_clean.boot"))
  }
}

function Test-ReleaseBootCommand([string]$CommandLine, [string[]]$BootCandidates) {
  if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }

  # Preserve argument boundaries while tolerating the nested quote layers
  # that cmd.exe can leave in Win32_Process.CommandLine.
  $command = $CommandLine.Replace('/', '\')
  $outsideQuotes = [bool[]]::new($command.Length + 1)
  $insideQuotes = $false
  $backslashes = 0
  for ($index = 0; $index -lt $command.Length; $index++) {
    $outsideQuotes[$index] = -not $insideQuotes
    $character = $command[$index]
    if ($character -eq '\') {
      $backslashes++
      continue
    }
    if ($character -eq '"' -and ($backslashes % 2) -eq 0) {
      $insideQuotes = -not $insideQuotes
    }
    $backslashes = 0
  }
  $outsideQuotes[$command.Length] = -not $insideQuotes

  # Erlang treats everything after -extra as user data, not emulator options.
  $optionsEnd = $command.Length
  foreach ($match in [regex]::Matches(
      $command,
      '(?:^|\s)(?<option>-extra)(?=\s|$)',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) {
    $optionIndex = $match.Groups["option"].Index
    if ($outsideQuotes[$optionIndex]) {
      $optionsEnd = $optionIndex
      break
    }
  }

  foreach ($boot in $BootCandidates) {
    $normalizedBoot = ([string]$boot).Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($normalizedBoot) -or $normalizedBoot.Contains('"')) { continue }
    $escapedBoot = [regex]::Escape($normalizedBoot)
    $quotedBoot = '(?<quotes>"+)' + $escapedBoot + '\k<quotes>'
    $bootValue = if ($normalizedBoot -match '\s') {
      $quotedBoot
    } else {
      '(?:' + $quotedBoot + '|' + $escapedBoot + ')'
    }
    $pattern = '(?:^|\s)(?<option>--?boot)(?:=|\s+)' + $bootValue + '(?=\s|$)'
    foreach ($match in [regex]::Matches(
        $command,
        $pattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
      )) {
      $optionIndex = $match.Groups["option"].Index
      if ($optionIndex -lt $optionsEnd -and $outsideQuotes[$optionIndex]) {
        return $true
      }
    }
  }
  $false
}

function Invoke-ReleaseWithDefaultEpmdPort([scriptblock]$Action) {
  # run-dala strips release and Erlang overrides, so lifecycle commands must
  # address the same default release even when the caller has ambient state.
  $names = @(
    "RELEASE_NAME", "RELEASE_VSN", "RELEASE_MODE", "RELEASE_NODE", "RELEASE_COOKIE",
    "RELEASE_TMP", "RELEASE_VM_ARGS", "RELEASE_REMOTE_VM_ARGS", "RELEASE_DISTRIBUTION",
    "RELEASE_BOOT_SCRIPT", "RELEASE_BOOT_SCRIPT_CLEAN", "RELEASE_SYS_CONFIG", "RELEASE_ROOT",
    "RELEASE_COMMAND", "RELEASE_PROG", "RELEASE_MUTABLE_DIR", "RELEASE_READ_ONLY",
    "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS", "ERL_LIBS", "ERL_INETRC",
    "ERL_EPMD_PORT", "ERL_EPMD_ADDRESS", "ERL_EPMD_RELAXED_COMMAND_CHECK",
    "ELIXIR_ERL_OPTIONS"
  )
  $previous = @{}
  try {
    foreach ($name in $names) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
      [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
    & $Action
  } finally {
    foreach ($name in $names) {
      if ($previous.ContainsKey($name)) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
      }
    }
  }
}

function Get-ReleaseBeamProcesses([string]$Executable) {
  $identity = Get-ReleaseIdentity $Executable
  if (-not $identity) { return @() }
  $lastIdentityError = $null
  for ($attempt = 0; $attempt -lt 5; $attempt++) {
    $releaseProcesses = @()
    $lastIdentityError = $null
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction Stop)) {
      if ($null -eq $process) {
        $lastIdentityError = "Cannot determine the identity of an erl.exe process; refusing to continue"
        break
      }

      $processExecutable = [string]$process.ExecutablePath
      if ([string]::IsNullOrWhiteSpace($processExecutable)) {
        $lastIdentityError = "Cannot determine the identity of an erl.exe process; refusing to continue"
        break
      }
      if (-not (Test-SamePath $processExecutable $identity.Executable)) { continue }

      $processCommandLine = [string]$process.CommandLine
      if ([string]::IsNullOrWhiteSpace($processCommandLine)) {
        $lastIdentityError = "Cannot determine the identity of an erl.exe process; refusing to continue"
        break
      }
      if (-not (Test-ReleaseBootCommand $processCommandLine @(
            $identity.Boot,
            $identity.BootFile,
            $identity.CleanBoot,
            $identity.CleanBootFile
          ))) {
        throw "Cannot confirm the Dala release identity of erl.exe at $processExecutable; refusing to continue"
      }
      if ($null -eq $process.PSObject.Properties["ProcessId"] -or
          [string]::IsNullOrWhiteSpace([string]$process.ProcessId)) {
        $lastIdentityError = "Cannot determine the process id of an erl.exe process; refusing to continue"
        break
      }
      $releaseProcesses += $process
    }

    if (-not $lastIdentityError) { return $releaseProcesses }
    if ($attempt -lt 4) { Start-Sleep -Milliseconds 50 }
  }
  throw $lastIdentityError
}

function Get-ReleaseEpmdProcesses($Identity) {
  $epmdPath = if ($Identity) { [string]$Identity.Epmd } else { $null }
  if ([string]::IsNullOrWhiteSpace($epmdPath)) { return @() }

  $releaseProcesses = @()
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='epmd.exe'" -ErrorAction Stop)) {
    if ($null -eq $process) {
      throw "Cannot determine the identity of an epmd.exe process; refusing to continue"
    }

    $processExecutable = [string]$process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($processExecutable)) {
      throw "Cannot determine the identity of an epmd.exe process; refusing to continue"
    }
    if (-not (Test-SamePath $processExecutable $epmdPath)) { continue }
    if ($null -eq $process.PSObject.Properties["ProcessId"] -or
        [string]::IsNullOrWhiteSpace([string]$process.ProcessId)) {
      throw "Cannot determine the process id of an epmd.exe process; refusing to continue"
    }
    if ($null -eq $process.PSObject.Properties["CommandLine"] -or
        [string]::IsNullOrWhiteSpace([string]$process.CommandLine)) {
      throw "Cannot determine the command line of an epmd.exe process; refusing to continue"
    }
    $releaseProcesses += $process
  }
  $releaseProcesses
}

function Test-ReleaseEpmdSafeToKill($Process) {
  $commandLine = [string]$Process.CommandLine
  if ([string]::IsNullOrWhiteSpace($commandLine)) {
    throw "Cannot determine the command line of an epmd.exe process; refusing to continue"
  }
  if ([regex]::IsMatch(
      $commandLine,
      '(?i)(?:^|\s)-{1,2}relaxed_command_check(?:=\S+)?(?=\s|$)')) {
    return $false
  }
  if ([regex]::IsMatch(
      $commandLine,
      '(?i)(?:^|\s)-{1,2}address(?:=|\s|$)')) {
    return $false
  }
  $hasPortToken = [regex]::IsMatch($commandLine, '(?i)(?:^|\s)-{1,2}port(?:=|\s|$)')
  if ($hasPortToken) {
    $portMatch = [regex]::Match(
      $commandLine,
      '(?i)(?:^|\s)-{1,2}port(?:=|\s+)(?:"([^"]+)"|([^\s]+))(?=\s|$)'
    )
    if (-not $portMatch.Success) { return $false }
    $portText = if ($portMatch.Groups[1].Success) {
      [string]$portMatch.Groups[1].Value
    } else {
      [string]$portMatch.Groups[2].Value
    }
    if ($portText -notmatch '^\d+$' -or [int]$portText -ne 4369) { return $false }
  }
  $processId = [uint32]$Process.ProcessId
  $listenerIds = @(
    Get-NetTCPConnection -State Listen -LocalPort 4369 -ErrorAction Stop |
      ForEach-Object {
        if ($null -eq $_.PSObject.Properties["OwningProcess"] -or
            [string]::IsNullOrWhiteSpace([string]$_.OwningProcess)) {
          throw "Cannot determine the owner of the epmd default-port listener; refusing to continue"
        }
        if ($null -eq $_.PSObject.Properties["LocalAddress"] -or
            [string]::IsNullOrWhiteSpace([string]$_.LocalAddress)) {
          throw "Cannot determine the address of the epmd default-port listener; refusing to continue"
        }
        if ([string]$_.LocalAddress -notin @("0.0.0.0", "127.0.0.1", "::", "::1", "::ffff:127.0.0.1")) {
          throw "epmd default-port listener is bound to a non-local address; refusing to continue"
        }
        [uint32]$_.OwningProcess
      } |
      Sort-Object -Unique
  )
  if ($listenerIds.Count -ne 1 -or $listenerIds[0] -ne $processId) {
    return $false
  }
  $true
}

function Get-ReleaseEpmdNames([string]$EpmdPath) {
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $EpmdPath
  $startInfo.Arguments = "-names"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  try {
    if (-not $process.Start()) { throw "Could not start epmd names probe: $EpmdPath" }
    if (-not $process.WaitForExit(2000)) {
      try { $process.Kill() } catch { }
      throw "epmd names probe timed out: $EpmdPath"
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0) {
      throw "epmd names probe failed: $EpmdPath ($stderr)"
    }
    "$stdout`n$stderr"
  } finally {
    $process.Dispose()
  }
}

function Invoke-ReleaseEpmdKill([string]$EpmdPath, [uint32]$ExpectedProcessId = 0) {
  if ($ExpectedProcessId -gt 0) {
    $identityRows = @(
      Get-CimInstance Win32_Process -Filter "Name='epmd.exe'" -ErrorAction Stop |
        Where-Object {
          [string]$_.ProcessId -eq [string]$ExpectedProcessId
        }
    )
    if ($identityRows.Count -ne 1 -or
        -not (Test-SamePath ([string]$identityRows[0].ExecutablePath) $EpmdPath) -or
        [string]::IsNullOrWhiteSpace([string]$identityRows[0].CommandLine)) {
      throw "epmd process identity changed; refusing to continue"
    }
    if (-not (Test-ReleaseEpmdSafeToKill $identityRows[0])) {
      throw "epmd process safety changed; refusing to continue"
    }
    $listenerIds = @(
      Get-NetTCPConnection -State Listen -LocalPort 4369 -ErrorAction Stop |
        ForEach-Object {
          if ($null -eq $_.PSObject.Properties["OwningProcess"] -or
              [string]::IsNullOrWhiteSpace([string]$_.OwningProcess)) {
            throw "Cannot determine the owner of the epmd default-port listener; refusing to continue"
          }
          if ($null -eq $_.PSObject.Properties["LocalAddress"] -or
              [string]::IsNullOrWhiteSpace([string]$_.LocalAddress)) {
            throw "Cannot determine the address of the epmd default-port listener; refusing to continue"
          }
          if ([string]$_.LocalAddress -notin @("0.0.0.0", "127.0.0.1", "::", "::1", "::ffff:127.0.0.1")) {
            throw "epmd default-port listener is bound to a non-local address; refusing to continue"
          }
          [uint32]$_.OwningProcess
        } |
        Sort-Object -Unique
    )
    if ($listenerIds.Count -ne 1 -or $listenerIds[0] -ne $ExpectedProcessId) {
      throw "epmd default-port listener ownership changed; refusing to continue"
    }
  }
  Invoke-ReleaseWithDefaultEpmdPort {
    try {
      & $EpmdPath -kill 2>$null | Out-Null
    } catch {
      # A daemon with registered nodes refuses -kill. Verification by CIM below
      # remains authoritative.
    }
  }
}

function Stop-ReleaseEpmd($Identity, [bool]$RequireStop = $false) {
  try {
    $epmdProcesses = @(Get-ReleaseEpmdProcesses $Identity)
  } catch {
    $message = "Could not inspect Dala release epmd before stopping it: $($_.Exception.Message)"
    if ($RequireStop) { throw $message }
    Write-Warning "$message; retaining the shared daemon" -WarningAction Continue
    return
  }
  $unsafeProcesses = @()
  try {
    $unsafeProcesses = @(
      $epmdProcesses | Where-Object { -not (Test-ReleaseEpmdSafeToKill $_) }
    )
  } catch {
    $message = "Could not verify Dala release epmd safety: $($_.Exception.Message)"
    if ($RequireStop) { throw $message }
    Write-Warning "$message; retaining the shared daemon" -WarningAction Continue
    return
  }
  if ($unsafeProcesses.Count -gt 0) {
    $message = "Dala release epmd is not a default, non-relaxed daemon; retaining it: $([string]$Identity.Epmd)"
    if ($RequireStop) { throw $message }
    Write-Warning $message -WarningAction Continue
    return
  }

  $epmdTargets = @(
    $epmdProcesses |
      Group-Object { [string]$_.ExecutablePath } |
      ForEach-Object { $_.Group[0] }
  )
  foreach ($epmdTarget in $epmdTargets) {
    $epmdPath = [string]$epmdTarget.ExecutablePath
    try {
      $names = [string](Invoke-ReleaseWithDefaultEpmdPort {
        Get-ReleaseEpmdNames $epmdPath
      })
    } catch {
      $message = "Could not inspect Dala release epmd before stopping it: $($_.Exception.Message)"
      if ($RequireStop) { throw $message }
      Write-Warning "$message; retaining the shared daemon" -WarningAction Continue
      return
    }
    if ([regex]::IsMatch($names, '(?im)^\s*name\s+\S+')) {
      $message = "Dala release epmd still has registered nodes; retaining it: $epmdPath"
      if ($RequireStop) { throw $message }
      Write-Warning $message -WarningAction Continue
      return
    }
    try {
      Invoke-ReleaseEpmdKill $epmdPath ([uint32]$epmdTarget.ProcessId)
    } catch {
      $message = "Could not safely stop Dala release epmd: $($_.Exception.Message)"
      if ($RequireStop) { throw $message }
      Write-Warning "$message; retaining the shared daemon" -WarningAction Continue
      return
    }
  }

  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    try {
      $remainingEpmd = @(Get-ReleaseEpmdProcesses $Identity)
    } catch {
      $message = "Could not verify Dala release epmd shutdown: $($_.Exception.Message)"
      if ($RequireStop) { throw $message }
      Write-Warning "$message; retaining the shared daemon" -WarningAction Continue
      return
    }
    $epmdFileAvailable = $false
    if ($remainingEpmd.Count -eq 0) {
      # CIM can observe process exit before Windows releases the executable's
      # image section.  Probe the actual file with an exclusive share before
      # allowing a caller to remove the release tree.
      $probe = $null
      try {
        $attributes = [IO.File]::GetAttributes([string]$Identity.Epmd)
        if (($attributes -band [IO.FileAttributes]::Directory) -eq 0 -and
            ($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
          $probe = [IO.File]::Open(
            [string]$Identity.Epmd,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
          )
          $epmdFileAvailable = $true
        }
      } catch [IO.FileNotFoundException] {
        $epmdFileAvailable = $true
      } catch [IO.DirectoryNotFoundException] {
        $epmdFileAvailable = $true
      } catch {
        # Access denied, a transient image lock, and malformed paths are not
        # evidence that the executable is absent; keep the wait fail-closed.
        $epmdFileAvailable = $false
      } finally {
        if ($probe) { $probe.Dispose() }
      }
    }
    if ($remainingEpmd.Count -eq 0 -and $epmdFileAvailable) { return }
    Start-Sleep -Milliseconds 100
  }

  $message = "Dala release epmd did not stop: $([string]$Identity.Epmd)"
  if ($RequireStop) { throw $message }
  Write-Warning "$message; retaining the shared daemon" -WarningAction Continue
}

function Stop-DalaRelease([string]$Executable, [bool]$RequireEpmdStop = $false) {
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

  $identity = Get-ReleaseIdentity $Executable

  # Avoid invoking the release client when no owned BEAM remains.  The client
  # can otherwise start or attach to epmd while rollback is trying to remove
  # the release tree.
  if (@(Get-ReleaseBeamProcesses $Executable).Count -eq 0) {
    Stop-ReleaseEpmd $identity $RequireEpmdStop
    return
  }

  try {
    Invoke-ReleaseWithDefaultEpmdPort {
      & $Executable stop 2>$null | Out-Null
    }
  } catch {
    # An unhealthy release may reject RPC stop. The identity-checked process
    # probes below remain authoritative and provide the force-stop fallback.
  }

  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if (@(Get-ReleaseBeamProcesses $Executable).Count -eq 0) {
      Stop-ReleaseEpmd $identity $RequireEpmdStop
      return
    }
    Start-Sleep -Milliseconds 100
  }

  foreach ($process in Get-ReleaseBeamProcesses $Executable) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if (@(Get-ReleaseBeamProcesses $Executable).Count -eq 0) {
      Stop-ReleaseEpmd $identity $RequireEpmdStop
      return
    }
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
  Stop-DalaRelease $Executable ([bool]$OnlyStop)
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
