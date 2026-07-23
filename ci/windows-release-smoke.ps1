[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ArchivePath,
  [Parameter(Mandatory = $true)][string]$ChecksumPath,
  [string]$InstallerScript = "install.ps1",
  [string]$UpdateScript = "update.ps1",
  [string]$UninstallScript = "uninstall.ps1"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Get-SmokeReleaseEnvironmentNames {
  @(
    "RELEASE_NAME", "RELEASE_VSN", "RELEASE_MODE", "RELEASE_NODE", "RELEASE_COOKIE",
    "RELEASE_TMP", "RELEASE_VM_ARGS", "RELEASE_REMOTE_VM_ARGS", "RELEASE_DISTRIBUTION",
    "RELEASE_BOOT_SCRIPT", "RELEASE_BOOT_SCRIPT_CLEAN", "RELEASE_SYS_CONFIG", "RELEASE_ROOT",
    "RELEASE_COMMAND", "RELEASE_PROG", "RELEASE_MUTABLE_DIR", "RELEASE_READ_ONLY",
    "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS", "ERL_LIBS", "ERL_INETRC",
    "ERL_EPMD_PORT", "ERL_EPMD_ADDRESS", "ERL_EPMD_RELAXED_COMMAND_CHECK",
    "ELIXIR_ERL_OPTIONS"
  )
}

function Invoke-SmokeReleaseWithCleanEnvironment([scriptblock]$Action) {
  $previous = @{}
  $names = @(Get-SmokeReleaseEnvironmentNames)
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

function Assert-SmokeReleaseEnvironmentIsolation {
  $names = @(Get-SmokeReleaseEnvironmentNames)
  $sentinel = "dala-smoke-ambient-" + [guid]::NewGuid().ToString("N")
  $original = @{}
  try {
    foreach ($name in $names) {
      $original[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
      [Environment]::SetEnvironmentVariable($name, $sentinel, "Process")
    }

    $observed = Invoke-SmokeReleaseWithCleanEnvironment {
      [pscustomobject]@{
        release_node = [Environment]::GetEnvironmentVariable("RELEASE_NODE", "Process")
        release_cookie = [Environment]::GetEnvironmentVariable("RELEASE_COOKIE", "Process")
        release_name = [Environment]::GetEnvironmentVariable("RELEASE_NAME", "Process")
        erl_epmd_port = [Environment]::GetEnvironmentVariable("ERL_EPMD_PORT", "Process")
        erl_flags = [Environment]::GetEnvironmentVariable("ERL_FLAGS", "Process")
      }
    }
    foreach ($property in $observed.PSObject.Properties) {
      Assert-True ([string]::IsNullOrEmpty([string]$property.Value)) `
        "Smoke release environment was not cleared: $($property.Name)"
    }
    foreach ($name in $names) {
      Assert-True ([Environment]::GetEnvironmentVariable($name, "Process") -ceq $sentinel) `
        "Smoke release environment was not restored: $name"
    }
  } finally {
    foreach ($name in $names) {
      if ($original.ContainsKey($name)) {
        [Environment]::SetEnvironmentVariable($name, $original[$name], "Process")
      }
    }
  }
}

function Assert-ReleaseEnvironmentIsolationSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Invoke-ReleaseWithDefaultEpmdPort"
    }, $true)
  )
  Assert-True ($definitions.Count -eq 1) "$ScriptPath must define exactly one release environment wrapper"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($definitions[0].Extent.Text))
  $names = @(Get-SmokeReleaseEnvironmentNames)
  $sentinel = "dala-production-ambient-" + [guid]::NewGuid().ToString("N")
  $original = @{}
  try {
    foreach ($name in $names) {
      $original[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
      [Environment]::SetEnvironmentVariable($name, $sentinel, "Process")
    }

    $observed = & $module {
      param([string[]]$EnvironmentNames)
      Invoke-ReleaseWithDefaultEpmdPort {
        $values = @{}
        foreach ($name in $EnvironmentNames) {
          $values[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        }
        [pscustomobject]$values
      }
    } $names
    foreach ($name in $names) {
      $value = if ($observed -and $observed.PSObject.Properties[$name]) {
        $observed.PSObject.Properties[$name].Value
      }
      Assert-True ([string]::IsNullOrEmpty([string]$value)) `
        "$ScriptPath left ambient $name set inside its release command"
      Assert-True ([Environment]::GetEnvironmentVariable($name, "Process") -ceq $sentinel) `
        "$ScriptPath did not restore $name after a successful release command"
    }

    $thrown = $false
    try {
      & $module { Invoke-ReleaseWithDefaultEpmdPort { throw "environment probe" } }
    } catch {
      $thrown = $_.Exception.Message -match "environment probe"
    }
    Assert-True $thrown "$ScriptPath swallowed an exception from its release command"
    foreach ($name in $names) {
      Assert-True ([Environment]::GetEnvironmentVariable($name, "Process") -ceq $sentinel) `
        "$ScriptPath did not restore $name after a failed release command"
    }
  } finally {
    foreach ($name in $names) {
      if ($original.ContainsKey($name)) {
        [Environment]::SetEnvironmentVariable($name, $original[$name], "Process")
      }
    }
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-SmokeLifecycleCommandSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @("Invoke-ReleaseRpc", "Set-SmokeTaskRunner", "Stop-SmokeRelease")
    }, $true)
  )
  foreach ($name in @("Invoke-ReleaseRpc", "Set-SmokeTaskRunner", "Stop-SmokeRelease")) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }
  $rpcBody = @($definitions | Where-Object { $_.Name -ceq "Invoke-ReleaseRpc" })[0].Extent.Text
  $runnerBody = @($definitions | Where-Object { $_.Name -ceq "Set-SmokeTaskRunner" })[0].Extent.Text
  $stopBody = @($definitions | Where-Object { $_.Name -ceq "Stop-SmokeRelease" })[0].Extent.Text
  Assert-True ($rpcBody -match "Invoke-SmokeReleaseWithCleanEnvironment") `
    "$ScriptPath does not isolate release RPC environment"
  Assert-True ($rpcBody -match "LASTEXITCODE") `
    "$ScriptPath does not verify release RPC exit status"
  Assert-True ($stopBody -match "Get-SmokeRestartHelper") `
    "$ScriptPath does not resolve the installed restart helper"
  Assert-True ($stopBody -match "StopOnly") `
    "$ScriptPath does not use the verified StopOnly release path"
  Assert-True ($stopBody -match "LASTEXITCODE") `
    "$ScriptPath does not verify release stop exit status"
  Assert-True ($runnerBody -match "Stop-SmokeRelease") `
    "$ScriptPath does not route task runner switches through verified release stop"
}

$SmokeAttemptIds = @{}

function New-SmokeAttemptId {
  do {
    $attemptId = [guid]::NewGuid().ToString("D")
  } while ($SmokeAttemptIds.ContainsKey($attemptId))
  $SmokeAttemptIds[$attemptId] = $true
  $attemptId
}

function Assert-UpdateResultAttempt($Result, [string]$AttemptId) {
  Assert-True ([string]$Result.attempt_id -ceq $AttemptId) "Update result does not match attempt $AttemptId"
}

function Assert-ReleaseEpmdKillSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @(
    "Test-SamePath",
    "Invoke-ReleaseWithDefaultEpmdPort",
    "Test-ReleaseEpmdSafeToKill",
    "Invoke-ReleaseEpmdKill"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }
  $scriptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptPath).Path)
  foreach ($name in @("RELEASE_NODE", "RELEASE_COOKIE", "ERL_FLAGS", "ELIXIR_ERL_OPTIONS")) {
    Assert-True ($scriptText -match [regex]::Escape($name)) `
      "$ScriptPath does not clear the ambient $name release override"
  }

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:rows = @()
      $script:listenerIds = @()
      $script:wrapperCalls = 0

      Set-Item -Path Function:Test-SamePath -Value {
        param([string]$Left, [string]$Right)
        $Left -ceq $Right
      }
      Set-Item -Path Function:Get-CimInstance -Value {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        $script:rows
      }
      Set-Item -Path Function:Get-NetTCPConnection -Value {
        [CmdletBinding()]
        param([string]$State, [int]$LocalPort)
        $script:listenerIds | ForEach-Object {
          [pscustomobject]@{ OwningProcess = [uint32]$_; LocalAddress = "127.0.0.1" }
        }
      }
      # Do not execute a fake epmd binary. This wrapper proves that the real
      # kill function reached the command only after its identity checks.
      Set-Item -Path Function:Invoke-ReleaseWithDefaultEpmdPort -Value {
        param([scriptblock]$Action)
        $script:wrapperCalls++
      }

      $script:rows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\epmd.exe"
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]74
      })
      $script:listenerIds = @([uint32]74)
      Invoke-ReleaseEpmdKill "C:\dala\epmd.exe" ([uint32]74)
      $validAccepted = $script:wrapperCalls -eq 1

      $script:wrapperCalls = 0
      $script:rows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\epmd.exe"
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]75
      })
      $pidRejected = $false
      try { Invoke-ReleaseEpmdKill "C:\dala\epmd.exe" ([uint32]74) } catch { $pidRejected = $true }
      $pidRevalidationHeld = $pidRejected -and $script:wrapperCalls -eq 0

      $script:rows = @([pscustomobject]@{
        ExecutablePath = "C:\foreign\epmd.exe"
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]74
      })
      $pathRejected = $false
      try { Invoke-ReleaseEpmdKill "C:\dala\epmd.exe" ([uint32]74) } catch { $pathRejected = $true }
      $pathRevalidationHeld = $pathRejected -and $script:wrapperCalls -eq 0

      $script:rows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\epmd.exe"
        CommandLine = ""
        ProcessId = [uint32]74
      })
      $commandRejected = $false
      try { Invoke-ReleaseEpmdKill "C:\dala\epmd.exe" ([uint32]74) } catch { $commandRejected = $true }
      $commandRevalidationHeld = $commandRejected -and $script:wrapperCalls -eq 0

      $script:rows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\epmd.exe"
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]74
      })
      $script:listenerIds = @([uint32]999)
      $listenerRejected = $false
      try { Invoke-ReleaseEpmdKill "C:\dala\epmd.exe" ([uint32]74) } catch { $listenerRejected = $true }
      $listenerRevalidationHeld = $listenerRejected -and $script:wrapperCalls -eq 0

      [pscustomobject]@{
        valid_kill_reached_wrapper = $validAccepted
        pid_revalidation_held = $pidRevalidationHeld
        path_revalidation_held = $pathRevalidationHeld
        command_revalidation_held = $commandRevalidationHeld
        listener_revalidation_held = $listenerRevalidationHeld
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Release epmd kill smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Enter-SmokeLifecycleMutex {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $name = "Global\DalaLifecycle-" + ($sid.Value -replace '[^0-9A-Za-z_-]', '_')
  $created = $false
  $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
  try {
    if (-not $mutex.WaitOne(0)) { throw "Smoke could not acquire the Dala lifecycle mutex" }
  } catch [Threading.AbandonedMutexException] {
  }
  $mutex
}

function Exit-SmokeLifecycleMutex($Mutex) {
  $Mutex.ReleaseMutex()
  $Mutex.Dispose()
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Write-SmokeReleaseProcessSnapshot(
  [string]$Label,
  [string]$ReleaseDir,
  [string]$SmokeRoot,
  [int]$Port
) {
  try {
    $startData = @(
      (Get-Content -LiteralPath (Join-Path $ReleaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+'
    )
    $expectedErl = if ($startData.Count -eq 2) {
      [IO.Path]::GetFullPath((Join-Path $ReleaseDir "erts-$($startData[0])\bin\erl.exe"))
    } else {
      $null
    }
    $expectedBoot = if ($startData.Count -eq 2) {
      [IO.Path]::GetFullPath((Join-Path $ReleaseDir "releases\$($startData[1])\start"))
    } else {
      $null
    }
    Write-Warning "$Label expected erl.exe: $expectedErl"
    Write-Warning "$Label expected boot: $expectedBoot"

    $rows = @(
      Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction Stop |
        Where-Object {
          $path = [string]$_.ExecutablePath
          $commandLine = [string]$_.CommandLine
          (-not [string]::IsNullOrWhiteSpace($expectedErl) -and
            -not [string]::IsNullOrWhiteSpace($path) -and
            (Test-SamePath $path $expectedErl)) -or
          (-not [string]::IsNullOrWhiteSpace($commandLine) -and
            $commandLine.IndexOf($SmokeRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        }
    )
    if ($rows.Count -eq 0) {
      Write-Warning "$Label found no release-related erl.exe process"
    }
    foreach ($row in $rows) {
      $snapshot = [ordered]@{
        processId = $row.ProcessId
        executablePath = [string]$row.ExecutablePath
        commandLine = [string]$row.CommandLine
      } | ConvertTo-Json -Compress
      Write-Warning "$Label erl.exe snapshot: $snapshot"
    }

    $listeners = @(
      Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
    )
    if ($listeners.Count -eq 0) {
      Write-Warning "$Label found no listener on port $Port"
    }
    foreach ($listener in $listeners) {
      Write-Warning (
        "$Label listener snapshot: address=$($listener.LocalAddress); " +
        "port=$($listener.LocalPort); processId=$($listener.OwningProcess)"
      )
    }
  } catch {
    Write-Warning "$Label process snapshot failed: $($_.Exception.Message)"
  }
}

function Assert-NoOwnedEpmdProcess([string]$EpmdPath, [string]$Label) {
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='epmd.exe'" -ErrorAction Stop)) {
    if ($null -eq $process -or
        [string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace([string]$process.CommandLine) -or
        [string]::IsNullOrWhiteSpace([string]$process.ProcessId)) {
      throw "$Label returned an epmd.exe process with incomplete identity"
    }
    if (Test-SamePath ([string]$process.ExecutablePath) $EpmdPath) {
      throw "$Label left release-owned epmd.exe running: $EpmdPath (PID $($process.ProcessId))"
    }
  }
}

function Assert-ScriptParses([string]$Path) {
  $tokens = $null
  $errors = $null
  $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    $details = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join "; "
    throw "PowerShell parser rejected $Path`: $details"
  }
}

function Assert-UninstallerMissingAppDataSemantics(
  [string]$ScriptPath,
  [string]$WorkDir
) {
  $root = Join-Path $WorkDir "missing appdata uninstall root"
  $discovery = Join-Path $WorkDir "missing appdata discovery\install.json"
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  $names = @("APPDATA", "DALA_HOME", "DALA_CONFIG", "DALA_DISCOVERY_FILE")
  $previous = @{}
  try {
    foreach ($name in $names) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    [Environment]::SetEnvironmentVariable("APPDATA", $null, "Process")
    [Environment]::SetEnvironmentVariable("DALA_HOME", $root, "Process")
    [Environment]::SetEnvironmentVariable("DALA_CONFIG", $null, "Process")
    [Environment]::SetEnvironmentVariable("DALA_DISCOVERY_FILE", $discovery, "Process")

    $rejected = $false
    try {
      & $ScriptPath
    } catch {
      if ($_.Exception.Message -notmatch "APPDATA is required when Dala metadata is unavailable") {
        throw
      }
      $rejected = $true
    }
    Assert-True $rejected "Uninstaller did not report missing APPDATA explicitly"
  } finally {
    foreach ($name in $names) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
    }
  }
}

function Assert-RunnerDiscoveryFallbackSemantics(
  [string]$ScriptPath,
  [string]$WorkDir
) {
  $root = Join-Path $WorkDir "runner fallback root"
  $foreignRoot = Join-Path $WorkDir "runner foreign root"
  $ambientAppData = Join-Path $WorkDir "runner ambient appdata"
  $config = Join-Path $WorkDir "runner config.jsonc"
  $discovery = Join-Path $ambientAppData "Dala\install.json"
  $otherDiscovery = Join-Path $WorkDir "runner other discovery\install.json"
  $missingDiscovery = Join-Path $WorkDir "runner missing discovery\install.json"
  $observed = Join-Path $WorkDir "runner observed discovery.txt"
  $tag = "v0.0.0"
  $bin = Join-Path $root "versions\$tag\bin"
  New-Item -ItemType Directory -Force -Path $bin, $foreignRoot | Out-Null
  Copy-Item -LiteralPath $ScriptPath -Destination (Join-Path $root "run-dala.ps1")
  [IO.File]::WriteAllText((Join-Path $root "current.txt"), "$tag`r`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($config, '{"server":true}', [Text.UTF8Encoding]::new($false))

  $batch = "@echo off`r`necho %DALA_DISCOVERY_FILE%>>`"$observed`"`r`nexit /b 0`r`n"
  [IO.File]::WriteAllText((Join-Path $bin "dala.bat"), $batch, [Text.UTF8Encoding]::new($false))

  $writeMetadata = {
    param([string]$Path, [string]$MetadataRoot, [string]$MetadataDiscovery)
    $value = [ordered]@{
      schemaVersion = 1
      root = $MetadataRoot
      dataDir = Join-Path $WorkDir "runner data"
      configFile = $config
      taskName = "DalaRunnerFallbackSmoke"
      port = 4400
      repo = "mjason/dala"
      platform = "windows-x86_64"
      discoveryFile = $MetadataDiscovery
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, ($value | ConvertTo-Json -Depth 4) + "`n", [Text.UTF8Encoding]::new($false))
  }

  $names = @("APPDATA", "DALA_HOME", "DALA_CONFIG", "DALA_DISCOVERY_FILE")
  $previous = @{}
  try {
    foreach ($name in $names) {
      $previous[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    [Environment]::SetEnvironmentVariable("APPDATA", $ambientAppData, "Process")
    [Environment]::SetEnvironmentVariable("DALA_HOME", $null, "Process")
    [Environment]::SetEnvironmentVariable("DALA_CONFIG", $null, "Process")
    [Environment]::SetEnvironmentVariable("DALA_DISCOVERY_FILE", $null, "Process")

    & $writeMetadata $discovery $root $discovery
    $goodOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File (Join-Path $root "run-dala.ps1") 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "Runner rejected same-root discovery fallback: $goodOutput"
    $observedPaths = @(Get-Content -LiteralPath $observed | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($observedPaths.Count -eq 2) "Runner did not pass discoveryFile to both release commands"
    foreach ($path in $observedPaths) {
      Assert-True (Test-SamePath $path $discovery) "Runner passed a non-canonical discoveryFile to the release"
    }

    Remove-Item -LiteralPath $observed -Force
    & $writeMetadata $discovery $foreignRoot $discovery
    $foreignOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File (Join-Path $root "run-dala.ps1") 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0 -and $foreignOutput -match "root does not match the runner location") `
      "Runner accepted discovery metadata for another installation root"
    Assert-True (-not (Test-Path -LiteralPath $observed)) `
      "Runner invoked the release after rejecting foreign-root discovery metadata"

    & $writeMetadata $discovery $root $otherDiscovery
    $pathOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File (Join-Path $root "run-dala.ps1") 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0 -and $pathOutput -match "discovery metadata disagrees with its path") `
      "Runner accepted discovery metadata whose discoveryFile points elsewhere"
    Assert-True (-not (Test-Path -LiteralPath $observed)) `
      "Runner invoked the release after rejecting inconsistent discoveryFile metadata"

    [Environment]::SetEnvironmentVariable("APPDATA", $null, "Process")
    [Environment]::SetEnvironmentVariable("DALA_DISCOVERY_FILE", $missingDiscovery, "Process")
    $missingConfigOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File (Join-Path $root "run-dala.ps1") 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0 -and
        $missingConfigOutput -match "Dala configuration is missing and APPDATA is not set") `
      "Runner did not report missing APPDATA explicitly when fallback metadata was absent"
    Assert-True (-not (Test-Path -LiteralPath $observed)) `
      "Runner invoked the release without metadata or a configuration fallback"
  } finally {
    foreach ($name in $names) {
      [Environment]::SetEnvironmentVariable($name, $previous[$name], "Process")
    }
  }
}

function Assert-InstallMetadataReparseReadSemantics([string[]]$ScriptPaths) {
  $workRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ("dala metadata read smoke " + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
  $links = @()

  try {
    $index = 0
    foreach ($scriptPath in $ScriptPaths) {
      $tokens = $null
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
      if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $scriptPath" }

      $requiredFunctions = @("Read-InstallMetadata", "Get-SafeInstallMetadataItem", "Test-NoReparseAncestors")
      $definitions = @(
        $ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $requiredFunctions -contains $node.Name
        }, $true) |
          Sort-Object { $_.Extent.StartOffset }
      )
      foreach ($name in $requiredFunctions) {
        Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
          "$scriptPath must define exactly one $name function"
      }

      $module = New-Module -ScriptBlock ([ScriptBlock]::Create(
          ($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
        ))
      try {
        $index++
        $target = Join-Path $workRoot ("target-$index.json")
        $link = Join-Path $workRoot ("metadata-link-$index.json")
        [IO.File]::WriteAllText($target, "metadata target must remain unchanged`n")
        New-Item -ItemType SymbolicLink -Path $link -Target $target | Out-Null
        $links += [pscustomobject]@{ Path = $link; Kind = "file" }

        $message = & $module {
          param([string]$Path)
          try {
            $null = Read-InstallMetadata $Path
            "accepted"
          } catch {
            $_.Exception.Message
          }
        } $link
        Assert-True ([string]$message -ne "accepted" -and
          [string]$message -match "(?i)(reparse|regular file)") `
          "$scriptPath followed a root metadata symbolic link"
        Assert-True ((Get-Content -LiteralPath $target -Raw) -ceq "metadata target must remain unchanged`n") `
          "$scriptPath changed the root metadata symlink target"

        $ancestorTarget = Join-Path $workRoot ("ancestor-target-$index")
        $ancestorLink = Join-Path $workRoot ("ancestor-link-$index")
        $ancestorMetadata = Join-Path $ancestorTarget "install.json"
        New-Item -ItemType Directory -Force -Path $ancestorTarget | Out-Null
        [IO.File]::WriteAllText($ancestorMetadata, "metadata ancestor target must remain unchanged`n")
        New-Item -ItemType Junction -Path $ancestorLink -Target $ancestorTarget | Out-Null
        $links += [pscustomobject]@{ Path = $ancestorLink; Kind = "directory" }

        $message = & $module {
          param([string]$Path)
          try {
            $null = Read-InstallMetadata $Path
            "accepted"
          } catch {
            $_.Exception.Message
          }
        } (Join-Path $ancestorLink "install.json")
        Assert-True ([string]$message -ne "accepted" -and
          [string]$message -match "(?i)(reparse|regular file)") `
          "$scriptPath followed a root metadata junction ancestor"
        Assert-True ((Get-Content -LiteralPath $ancestorMetadata -Raw) -ceq "metadata ancestor target must remain unchanged`n") `
          "$scriptPath changed metadata below a junction ancestor"
      } finally {
        Remove-Module $module -Force -ErrorAction SilentlyContinue
      }
    }
  } finally {
    foreach ($link in @($links | Sort-Object { $_.Kind -ne "directory" })) {
      if ($link.Kind -ceq "directory") {
        [IO.Directory]::Delete($link.Path)
      } else {
        [IO.File]::Delete($link.Path)
      }
    }
    if (Test-Path -LiteralPath $workRoot) {
      Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

function Assert-MetadataFieldCasingSemantics([string[]]$ScriptPaths) {
  foreach ($scriptPath in $ScriptPaths) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $scriptPath" }

    $definitions = @(
      $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $node.Name -ceq "Get-MetadataField"
      }, $true)
    )
    Assert-True ($definitions.Count -eq 1) "$scriptPath must define exactly one Get-MetadataField function"
    $functionText = $definitions[0].Extent.Text
    Assert-True (
      $functionText -match '(?s)\$discoveryProperties\s*=\s*@\(' -and
      $functionText -match '(?s)\$discoveryProperties\.Count\s+-gt\s+1' -and
      $functionText -match '(?s)\[string\]\(\$discoveryProperties\[0\]\.Name\)\s+-cne\s+\$Name'
    ) "$scriptPath does not reject duplicate discoveryFile keys with different casing"

    $module = New-Module -ScriptBlock ([ScriptBlock]::Create($definitions[0].Extent.Text))
    try {
      $aliasRejected = $false
      try {
        $null = & $module {
          Get-MetadataField ([pscustomobject]@{ DiscoveryFile = "C:\Dala\install.json" }) "discoveryFile"
        }
      } catch {
        if ($_.Exception.Message -match "invalid casing") {
          $aliasRejected = $true
        } else {
          throw
        }
      }
      Assert-True $aliasRejected "$scriptPath silently accepted a case-variant discoveryFile field"

      $duplicateRejected = $false
      try {
        $null = & $module {
          $metadata = ConvertFrom-Json `
            '{"discoveryFile":"canonical","DiscoveryFile":"case-variant"}' `
            -ErrorAction Stop
          Get-MetadataField $metadata "discoveryFile"
        }
      } catch {
        # A runtime may reject the duplicate keys while decoding; if it
        # preserves both properties, the field helper must reject them.
        if ($_.Exception.Message -match "(?i)(duplicate|different casing|invalid casing)") {
          $duplicateRejected = $true
        } else {
          throw
        }
      }
      Assert-True $duplicateRejected "$scriptPath accepted duplicate discoveryFile keys with different casing"

      $exact = & $module {
        Get-MetadataField ([pscustomobject]@{ discoveryFile = "C:\Dala\install.json" }) "discoveryFile"
      }
      Assert-True ($exact.Present -and [string]$exact.Value -ceq "C:\Dala\install.json") `
        "$scriptPath rejected the canonical discoveryFile field"

      $other = & $module {
        Get-MetadataField ([pscustomobject]@{ Port = "4400" }) "port"
      }
      Assert-True (-not $other.Present) "$scriptPath changed casing behavior for non-discovery metadata fields"
    } finally {
      Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
  }
}

function Assert-CustomDiscoveryFileNameSemantics([string[]]$ScriptPaths) {
  foreach ($scriptPath in $ScriptPaths) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $scriptPath" }

    $definitions = @(
      $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          @(
            "Test-NormalWindowsDiscoveryPath",
            "Test-NoReparseAncestors",
            "Get-CanonicalDiscoveryFile"
          ) -contains $node.Name
      }, $true) |
        Sort-Object { $_.Extent.StartOffset }
    )
    $names = @($definitions | ForEach-Object { $_.Name })
    Assert-True ($names -contains "Test-NormalWindowsDiscoveryPath" -and
      $names -contains "Test-NoReparseAncestors" -and
      $names -contains "Get-CanonicalDiscoveryFile") `
      "$scriptPath must define discovery path validation helpers"

    $module = New-Module -ScriptBlock ([ScriptBlock]::Create(
        ($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
    ))
    try {
      foreach ($validPath in @(
        'C:\Dala\metadata.json',
        'z:/Dala/custom metadata.v2.json',
        '\\server\share\metadata.json',
        '\\server/share/path.with.dots/metadata.json'
      )) {
        $accepted = & $module {
          param([string]$Path)
          Test-NormalWindowsDiscoveryPath $Path
        } $validPath
        Assert-True ([bool]$accepted) "$scriptPath rejected normal discovery path: $validPath"
      }

      $invalidPaths = @(
        'relative\metadata.json',
        'C:metadata.json',
        '/Dala/metadata.json',
        '\\?\C:\Dala\metadata.json',
        '\\.\pipe\metadata.json',
        '\\?/C:/Dala/metadata.json',
        'C:\Dala\metadata.json:stream',
        'C:\Dala\metadata.json\',
        '\\server\share',
        '\\server\share\',
        'C:\Dala\.\metadata.json',
        'C:\Dala\..\metadata.json',
        'C:\Dala\directory.\metadata.json',
        'C:\Dala\directory \metadata.json',
        'C:\Dala\\metadata.json',
        'C:\Dala\CON',
        'C:\Dala\CON .txt',
        'C:\Dala\prn.json',
        'C:\Dala\AUX.metadata.json',
        'C:\Dala\nul.txt',
        'C:\Dala\CONIN$.json',
        'C:\Dala\conin$.json',
        'C:\Dala\CONOUT$.json',
        'C:\Dala\CLOCK$.json',
        'C:\Dala\COM1.json',
        'C:\Dala\com9',
        'C:\Dala\LPT1',
        'C:\Dala\lpt9.metadata',
        'C:\Dala\bad<name.json',
        'C:\Dala\bad>name.json',
        'C:\Dala\bad"name.json',
        'C:\Dala\bad|name.json',
        'C:\Dala\bad?name.json',
        'C:\Dala\bad*name.json'
      )
      foreach ($code in @(0, 1, 31)) {
        $invalidPaths += "C:\Dala\bad" + [char]$code + "name.json"
      }
      foreach ($suffix in @([char]0x00B9, [char]0x00B2, [char]0x00B3)) {
        $invalidPaths += "C:\Dala\COM" + $suffix + ".json"
        $invalidPaths += "C:\Dala\LPT" + $suffix + ".json"
      }
      foreach ($invalidPath in $invalidPaths) {
        $accepted = & $module {
          param([string]$Path)
          Test-NormalWindowsDiscoveryPath $Path
        } $invalidPath
        Assert-True (-not [bool]$accepted) "$scriptPath accepted invalid discovery path: $invalidPath"
      }

      $thread = [Threading.Thread]::CurrentThread
      $previousCulture = $thread.CurrentCulture
      $previousUICulture = $thread.CurrentUICulture
      try {
        $turkish = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
        $thread.CurrentCulture = $turkish
        $thread.CurrentUICulture = $turkish
        $accepted = & $module {
          param([string]$Path)
          Test-NormalWindowsDiscoveryPath $Path
        } 'C:\Dala\conin$.json'
        Assert-True (-not [bool]$accepted) `
          "$scriptPath accepted CONIN$ under the Turkish culture"
      } finally {
        $thread.CurrentCulture = $previousCulture
        $thread.CurrentUICulture = $previousUICulture
      }

      $canonicalRejected = $false
      try {
        $null = & $module {
          Get-CanonicalDiscoveryFile 'relative\metadata.json' $null
        }
      } catch {
        if ($_.Exception.Message -match "absolute Windows path") {
          $canonicalRejected = $true
        } else {
          throw
        }
      }
      Assert-True $canonicalRejected "$scriptPath canonicalized a path rejected by its syntax helper"

      $candidate = if ([IO.Path]::GetTempPath() -match '^[A-Za-z]:[\\/]') {
        Join-Path ([IO.Path]::GetTempPath()) `
          ("dala-custom-discovery-" + [guid]::NewGuid().ToString("N") + "\metadata.json")
      } else {
        "C:/Dala/" + [guid]::NewGuid().ToString("N") + "/metadata.json"
      }
      $resolved = & $module {
        param([string]$Path)
        Get-CanonicalDiscoveryFile $Path $null
      } $candidate
      Assert-True ([IO.Path]::GetFileName([string]$resolved) -ceq "metadata.json") `
        "$scriptPath rejected a valid custom discovery metadata filename"
    } finally {
      Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
  }
}

function Assert-ReleaseBootCommandSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Test-ReleaseBootCommand"
    }, $true)
  )
  Assert-True ($definitions.Count -eq 1) "$ScriptPath must define exactly one Test-ReleaseBootCommand function"

  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($definitions[0].Extent.Text))
  try {
    $result = & $module {
      $boot = "C:\Dala Release\releases\1.2.3\start"
      $compactBoot = "C:\Dala\releases\1.2.3\start"
      $ordinary = Test-ReleaseBootCommand -CommandLine (
        '"C:\Dala Release\erts-14\bin\erl.exe" -boot "' + $boot + '" -noshell'
      ) -BootCandidates @($boot)
      $doubled = Test-ReleaseBootCommand -CommandLine (
        '""C:\Dala Release\erts-14\bin\erl.exe"" -boot ""' + $boot + '"" -noshell'
      ) -BootCandidates @($boot)
      $tripledEquals = Test-ReleaseBootCommand -CommandLine (
        '"""C:\Dala Release\erts-14\bin\erl.exe""" --boot="""' + $boot + '""" -noshell'
      ) -BootCandidates @($boot)
      $forwardSlash = Test-ReleaseBootCommand -CommandLine (
        'erl.exe --boot="' + $boot.Replace('\', '/') + '" -noshell'
      ) -BootCandidates @($boot)
      $unquotedCompact = Test-ReleaseBootCommand -CommandLine (
        'erl.exe -boot ' + $compactBoot + ' -noshell'
      ) -BootCandidates @($compactBoot)
      $suffixRejected = -not (Test-ReleaseBootCommand -CommandLine (
          'erl.exe -boot ""' + $boot + '-foreign"" -noshell'
        ) -BootCandidates @($boot))
      $prefixedFlagRejected = -not (Test-ReleaseBootCommand -CommandLine (
          'erl.exe foreign-boot ""' + $boot + '"" -noshell'
        ) -BootCandidates @($boot))
      $quotedFlagRejected = -not (Test-ReleaseBootCommand -CommandLine (
          'erl.exe "ignored -boot ' + $compactBoot + '" -noshell'
        ) -BootCandidates @($compactBoot))
      $splitPathRejected = -not (Test-ReleaseBootCommand -CommandLine (
          'erl.exe -boot "C:\Dala" "Release\releases\1.2.3\start" -noshell'
        ) -BootCandidates @($boot))
      $unquotedWhitespaceRejected = -not (Test-ReleaseBootCommand -CommandLine (
          'erl.exe -boot ' + $boot + ' -noshell'
        ) -BootCandidates @($boot))
      $extraRejected = -not (Test-ReleaseBootCommand -CommandLine (
          'erl.exe -noshell -extra -boot "' + $boot + '"'
        ) -BootCandidates @($boot))
      $emptyRejected = -not (Test-ReleaseBootCommand -CommandLine "" -BootCandidates @($boot))

      [pscustomobject]@{
        ordinary_quote_accepted = $ordinary
        doubled_quote_accepted = $doubled
        tripled_equals_quote_accepted = $tripledEquals
        forward_slash_accepted = $forwardSlash
        unquoted_compact_path_accepted = $unquotedCompact
        boot_suffix_rejected = $suffixRejected
        prefixed_flag_rejected = $prefixedFlagRejected
        quoted_flag_rejected = $quotedFlagRejected
        split_path_rejected = $splitPathRejected
        unquoted_whitespace_rejected = $unquotedWhitespaceRejected
        post_extra_flag_rejected = $extraRejected
        empty_command_rejected = $emptyRejected
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "$ScriptPath release boot command smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-BestEffortReleaseStop($Definitions, [string]$ScriptPath) {
  $stopDefinitions = @($Definitions | Where-Object { $_.Name -ceq "Stop-DalaRelease" })
  Assert-True ($stopDefinitions.Count -eq 1) "$ScriptPath must define exactly one Stop-DalaRelease function"
  $stopBody = $stopDefinitions[0].Extent.Text
  Assert-True ([regex]::IsMatch(
      $stopBody,
      'try\s*\{[\s\S]*?&\s+\$Executable\s+stop[\s\S]*?\}\s*catch\s*\{',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath does not treat graceful release stop as best-effort"
}

function Assert-DalaExecutableIdentity([string]$ScriptPath, [string]$ReleaseDir, [string]$Version) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @("Test-SamePath", "Get-ReleaseVersion", "Get-ReleaseIdentity")
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in @("Test-SamePath", "Get-ReleaseIdentity")) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $moduleBody = @(
    '$TagPattern = ''^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'''
    $definitions | ForEach-Object { $_.Extent.Text }
  ) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))

  try {
    $dalaExecutable = [IO.Path]::GetFullPath((Join-Path $ReleaseDir "bin\dala.bat"))
    $identity = & $module { param($Path) Get-ReleaseIdentity $Path } $dalaExecutable
    Assert-True ($null -ne $identity) "$ScriptPath did not resolve identity from bin\dala.bat"

    $startData = @((Get-Content -LiteralPath (Join-Path $ReleaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
    Assert-True ($startData.Count -eq 2 -and [string]$startData[1] -ceq $Version) `
      "Release fixture has malformed start_erl.data"
    $expectedErl = Join-Path $ReleaseDir "erts-$($startData[0])\bin\erl.exe"
    $expectedEpmd = Join-Path $ReleaseDir "erts-$($startData[0])\bin\epmd.exe"
    $expectedBoot = Join-Path $ReleaseDir "releases\$Version\start"
    $expectedBootFile = Join-Path $ReleaseDir "releases\$Version\start.boot"
    $expectedCleanBoot = Join-Path $ReleaseDir "releases\$Version\start_clean"
    $expectedCleanBootFile = Join-Path $ReleaseDir "releases\$Version\start_clean.boot"
    Assert-True (Test-SamePath ([string]$identity.Executable) $expectedErl) `
      "$ScriptPath resolved the wrong erl.exe from bin\dala.bat"
    Assert-True (Test-SamePath ([string]$identity.Epmd) $expectedEpmd) `
      "$ScriptPath resolved the wrong epmd.exe from bin\dala.bat"
    Assert-True (Test-SamePath ([string]$identity.Boot) $expectedBoot) `
      "$ScriptPath resolved the wrong -boot path from bin\dala.bat"
    Assert-True (Test-SamePath ([string]$identity.BootFile) $expectedBootFile) `
      "$ScriptPath resolved the wrong start.boot path from bin\dala.bat"
    Assert-True (Test-SamePath ([string]$identity.CleanBoot) $expectedCleanBoot) `
      "$ScriptPath resolved the wrong start_clean path from bin\dala.bat"
    Assert-True (Test-SamePath ([string]$identity.CleanBootFile) $expectedCleanBootFile) `
      "$ScriptPath resolved the wrong start_clean.boot path from bin\dala.bat"
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Write-DalaIdentityFixture(
  [string]$SourceRelease,
  [string]$Destination,
  [string]$Version,
  [switch]$Runnable
) {
  $startData = @((Get-Content -LiteralPath (Join-Path $SourceRelease "releases\start_erl.data") -Raw).Trim() -split '\s+')
  Assert-True ($startData.Count -eq 2 -and [string]$startData[1] -ceq $Version) `
    "Release fixture has malformed start_erl.data"

  foreach ($relative in @(
    "bin\dala.bat",
    "releases\start_erl.data",
    "releases\$Version\start.boot",
    "releases\$Version\start_clean.boot",
    "erts-$($startData[0])\bin\erl.exe",
    "erts-$($startData[0])\bin\epmd.exe"
  )) {
    $source = Join-Path $SourceRelease $relative
    Assert-True (Test-Path -LiteralPath $source -PathType Leaf) "Release fixture is missing $relative"
    $target = Join-Path $Destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
  }

  if ($Runnable) {
    $ertsRelative = "erts-$($startData[0])"
    $sourceErts = Join-Path $SourceRelease $ertsRelative
    $targetErts = Join-Path $Destination $ertsRelative
    Assert-True (Test-Path -LiteralPath $sourceErts -PathType Container) `
      "Release fixture is missing $ertsRelative"
    Get-ChildItem -LiteralPath $sourceErts -Force |
      Copy-Item -Destination $targetErts -Recurse -Force
  }
}

function Assert-InstallerJsoncSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @("ConvertFrom-DalaJsonc", "Get-DalaConfigProperty")
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))

  try {
    $joinedTokensAccepted = $false
    try {
      $null = & $module { ConvertFrom-DalaJsonc '{"port": 4/* must be whitespace */400}' }
      $joinedTokensAccepted = $true
    } catch {
    }
    Assert-True (-not $joinedTokensAccepted) "JSONC block comments joined otherwise invalid number tokens"

    $valid = & $module {
      $config = ConvertFrom-DalaJsonc '{"port": /* comment */ 4400,}'
      Get-DalaConfigProperty $config "port"
    }
    Assert-True ([int]$valid -eq 4400) "JSONC block comments or trailing commas stopped parsing"

    $wrongCase = & $module {
      $config = ConvertFrom-DalaJsonc '{"Port": 4555}'
      Get-DalaConfigProperty $config "port"
    }
    Assert-True ($null -eq $wrongCase) "Installer accepted a JSON key with runtime-incompatible casing"
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-InstallerArtifactRollbackSemantics([string]$ScriptPath, [string]$WorkDir) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  # A repaired release is the only durable copy of the pre-install tree until
  # the update helper has committed successfully. Failure paths must leave it
  # available for manual recovery rather than deleting it unconditionally.
  $installerBody = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptPath).Path)
  $repairBackupRemovals = [regex]::Matches(
    $installerBody,
    'Remove-SafeInstallTree\s+\$ReplacedDestinationBackup',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  Assert-True ($repairBackupRemovals.Count -eq 1) `
    "$ScriptPath must only remove the repaired release backup on the success path"

  $requiredFunctions = @(
    "Invoke-RecoverableFileReplace",
    "Write-TextAtomic",
    "Write-JsonAtomic",
    "Test-SamePath",
    "Write-InstallMetadataPair",
    "Assert-SafeMetadataTarget",
    "Test-NoReparseAncestors",
    "Remove-CreatedInstallArtifact",
    "Restore-InstallArtifacts"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $scriptText = [IO.File]::ReadAllText($ScriptPath)
  foreach ($pattern in @(
    'Write-TextAtomic\s+\(Join-Path\s+\$Root\s+"\.dala-install"\)',
    'Write-TextAtomic\s+\(Join-Path\s+\$DataDir\s+"\.dala-data"\)',
    'Write-TextAtomic\s+\$ConfigMarker\s+"Dala configuration directory'
  )) {
    Assert-True ([regex]::IsMatch($scriptText, $pattern)) `
      "$ScriptPath does not route every ownership marker through Write-TextAtomic"
  }
  Assert-True ([regex]::IsMatch(
      $scriptText,
      'Write-InstallMetadataPair\s+\$RootMetadataFile\s+\$DiscoveryFile\s+\$metadata\s+' +
        '\(\[ref\]\$MetadataRollbackIncomplete\)\s+' +
        '\$MetadataWritten\s*=\s*\$true\s+\$CanRollbackCreatedArtifacts\s*=\s*\$false'
    )) "Existing install does not commit created artifacts with its metadata pair"
  $metadataWrites = [regex]::Matches(
    $scriptText,
    'Write-InstallMetadataPair\s+\$RootMetadataFile\s+\$DiscoveryFile\s+\$metadata\s+' +
      '\(\[ref\]\$MetadataRollbackIncomplete\)',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  Assert-True ($metadataWrites.Count -eq 2) `
    "Installer does not track incomplete rollback for both metadata-pair writes"
  Assert-True ([regex]::IsMatch(
      $scriptText,
      '-RestoreMetadata\s+\(\$MetadataWritten\s+-or\s+\$MetadataRollbackIncomplete\)'
    )) "Installer does not retry metadata restoration after an incomplete pair rollback"

  $orphanRepairGuard = $scriptText.IndexOf(
    'if ($orphanRepairs.Count -gt 0)',
    [StringComparison]::Ordinal
  )
  $repairCommit = $scriptText.IndexOf(
    'Move-Item -LiteralPath $Dest -Destination $backup -ErrorAction Stop',
    [StringComparison]::Ordinal
  )
  Assert-True ($orphanRepairGuard -ge 0 -and $repairCommit -gt $orphanRepairGuard) `
    "Installer does not reject orphan repair backups before moving a damaged release"
  Assert-True ($scriptText.IndexOf(
      'Move-Item -LiteralPath $backup -Destination $Dest -ErrorAction Stop',
      [StringComparison]::Ordinal
    ) -gt $repairCommit) "Installer does not make damaged-release restoration errors terminating"
  Assert-True ($scriptText -match 'could not restore original release from') `
    "Installer does not surface damaged-release restoration failures"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  $caseRoot = Join-Path $WorkDir "installer artifact rollback"
  New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

  try {
    $preservedRoot = Join-Path $caseRoot "root-preserved.json"
    $createdDiscovery = Join-Path $caseRoot "discovery-created.json"
    $createdConfig = Join-Path $caseRoot "config-created.jsonc"
    $createdMarker = Join-Path $caseRoot ".dala-config-created"
    [IO.File]::WriteAllText($preservedRoot, "original root metadata")
    [IO.File]::WriteAllText($createdDiscovery, "new discovery metadata")
    [IO.File]::WriteAllText($createdConfig, "new config")
    [IO.File]::WriteAllText($createdMarker, "new marker")
    [IO.File]::WriteAllText($preservedRoot, "replacement root metadata")

    & $module {
      param($Root, $Discovery, $Config, $Marker)
      Restore-InstallArtifacts `
        -RootMetadataPath $Root -RootMetadataExisted $true -RootMetadataBody "original root metadata" `
        -DiscoveryMetadataPath $Discovery -DiscoveryMetadataExisted $false -DiscoveryMetadataBody $null `
        -RestoreMetadata $true `
        -ConfigPath $Config -CreatedConfig $true `
        -ConfigMarkerPath $Marker -CreatedConfigMarker $true
    } $preservedRoot $createdDiscovery $createdConfig $createdMarker

    Assert-True ((Get-Content -LiteralPath $preservedRoot -Raw) -ceq "original root metadata") `
      "Artifact rollback removed original root metadata"
    foreach ($path in @($createdDiscovery, $createdConfig, $createdMarker)) {
      Assert-True (-not (Test-Path -LiteralPath $path)) "Artifact rollback left a created file at $path"
    }

    $createdRoot = Join-Path $caseRoot "root-created.json"
    $preservedDiscovery = Join-Path $caseRoot "discovery-preserved.json"
    [IO.File]::WriteAllText($createdRoot, "new root metadata")
    [IO.File]::WriteAllText($preservedDiscovery, "original discovery metadata")
    [IO.File]::WriteAllText($preservedDiscovery, "replacement discovery metadata")
    & $module {
      param($Root, $Discovery, $Config, $Marker)
      Restore-InstallArtifacts `
        -RootMetadataPath $Root -RootMetadataExisted $false -RootMetadataBody $null `
        -DiscoveryMetadataPath $Discovery -DiscoveryMetadataExisted $true `
        -DiscoveryMetadataBody "original discovery metadata" -RestoreMetadata $true `
        -ConfigPath $Config -CreatedConfig $false `
        -ConfigMarkerPath $Marker -CreatedConfigMarker $false
    } $createdRoot $preservedDiscovery $createdConfig $createdMarker

    Assert-True (-not (Test-Path -LiteralPath $createdRoot)) `
      "Artifact rollback left root metadata created beside an original discovery file"
    Assert-True ((Get-Content -LiteralPath $preservedDiscovery -Raw) -ceq "original discovery metadata") `
      "Artifact rollback removed original discovery metadata"

    $blockedMetadata = Join-Path $caseRoot "metadata-restore-blocked"
    $configKeptForMetadata = Join-Path $caseRoot "config-kept-for-metadata.jsonc"
    $markerKeptForMetadata = Join-Path $caseRoot ".marker-kept-for-metadata"
    New-Item -ItemType Directory -Path $blockedMetadata | Out-Null
    [IO.File]::WriteAllText($configKeptForMetadata, "keep config")
    [IO.File]::WriteAllText($markerKeptForMetadata, "keep marker")
    $metadataRestoreFailed = $false
    try {
      & $module {
        param($Root, $Discovery, $Config, $Marker)
        Restore-InstallArtifacts `
          -RootMetadataPath $Root -RootMetadataExisted $true -RootMetadataBody "original metadata" `
          -DiscoveryMetadataPath $Discovery -DiscoveryMetadataExisted $false -DiscoveryMetadataBody $null `
          -RestoreMetadata $true `
          -ConfigPath $Config -CreatedConfig $true `
          -ConfigMarkerPath $Marker -CreatedConfigMarker $true
      } $blockedMetadata (Join-Path $caseRoot "metadata-restore-missing.json") `
        $configKeptForMetadata $markerKeptForMetadata
    } catch {
      $metadataRestoreFailed = $true
    }
    Assert-True $metadataRestoreFailed "Artifact rollback ignored a metadata restore failure"
    Assert-True (Test-Path -LiteralPath $configKeptForMetadata -PathType Leaf) `
      "Metadata restore failure removed the config needed by uncertain metadata"
    Assert-True (Test-Path -LiteralPath $markerKeptForMetadata -PathType Leaf) `
      "Metadata restore failure removed the config ownership marker"

    $blockedConfig = Join-Path $caseRoot "config-cleanup-blocked"
    $markerKeptForConfig = Join-Path $caseRoot ".marker-kept-for-config"
    New-Item -ItemType Directory -Path $blockedConfig | Out-Null
    [IO.File]::WriteAllText($markerKeptForConfig, "keep marker")
    $configCleanupFailed = $false
    try {
      & $module {
        param($Config, $Marker)
        Restore-InstallArtifacts `
          -RootMetadataPath "" -RootMetadataExisted $false -RootMetadataBody $null `
          -DiscoveryMetadataPath "" -DiscoveryMetadataExisted $false -DiscoveryMetadataBody $null `
          -RestoreMetadata $false `
          -ConfigPath $Config -CreatedConfig $true `
          -ConfigMarkerPath $Marker -CreatedConfigMarker $true
      } $blockedConfig $markerKeptForConfig
    } catch {
      $configCleanupFailed = $true
    }
    Assert-True $configCleanupFailed "Artifact rollback ignored a config cleanup failure"
    Assert-True (Test-Path -LiteralPath $markerKeptForConfig -PathType Leaf) `
      "Config cleanup failure removed the ownership marker needed for a safe retry"

    $outsideMarkerTarget = Join-Path $caseRoot "outside-marker-target.txt"
    $markerLink = Join-Path $caseRoot ".dala-config-link"
    [IO.File]::WriteAllText($outsideMarkerTarget, "must remain unchanged")
    New-Item -ItemType SymbolicLink -Path $markerLink -Target $outsideMarkerTarget | Out-Null
    try {
      $markerRejected = $false
      try {
        & $module { param($Path) Write-TextAtomic $Path "Dala configuration directory`n" } $markerLink
      } catch {
        if ($_.Exception.Message -notmatch "reparse") { throw }
        $markerRejected = $true
      }
      Assert-True $markerRejected "Installer marker write followed a file reparse point"
      Assert-True ((Get-Content -LiteralPath $outsideMarkerTarget -Raw) -ceq "must remain unchanged") `
        "Installer marker write changed the reparse target"
    } finally {
      if (Test-Path -LiteralPath $markerLink) { [IO.File]::Delete($markerLink) }
    }

    $createdPairRoot = Join-Path $caseRoot "pair-created-root.json"
    $createdPairDiscovery = Join-Path $caseRoot "pair-created-discovery.json"
    $createdPairResult = & $module {
      param($Root, $Discovery)
      $script:injectedCreatedPairWriteCount = 0
      Set-Item -Path Function:Write-JsonAtomic -Value {
        param([string]$Path, $Value)
        $script:injectedCreatedPairWriteCount++
        if ($script:injectedCreatedPairWriteCount -eq 1) {
          [IO.Directory]::CreateDirectory($Path) | Out-Null
          [IO.File]::WriteAllText((Join-Path $Path "rollback-blocker.txt"), "keep")
          return
        }
        throw "injected second metadata write failure"
      }

      $rollbackIncomplete = $false
      $errorMessage = $null
      try {
        Write-InstallMetadataPair $Root $Discovery ([ordered]@{ schemaVersion = 1 }) `
          ([ref]$rollbackIncomplete)
      } catch {
        $errorMessage = $_.Exception.Message
      }
      [pscustomobject]@{
        rollback_incomplete = $rollbackIncomplete
        error = $errorMessage
      }
    } $createdPairRoot $createdPairDiscovery

    Assert-True ([bool]$createdPairResult.rollback_incomplete) `
      "Metadata pair ignored a failure deleting metadata created by this attempt"
    Assert-True ([string]$createdPairResult.error -match "install metadata rollback failed") `
      "Metadata pair did not surface its created-file deletion failure"
    Assert-True (Test-Path -LiteralPath (Join-Path $createdPairRoot "rollback-blocker.txt") -PathType Leaf) `
      "Metadata pair discarded the artifact whose rollback state is uncertain"

    $pairRoot = Join-Path $caseRoot "pair-root.json"
    $pairDiscovery = Join-Path $caseRoot "pair-discovery.json"
    $pairBackup = "$pairRoot.backup-stuck"
    [IO.File]::WriteAllText($pairRoot, "old root")
    [IO.File]::WriteAllText($pairDiscovery, "old discovery")
    New-Item -ItemType Directory -Path $pairBackup | Out-Null
    $pairResult = & $module {
      param($Root, $Discovery)
      $script:injectedPairWriteCount = 0
      Set-Item -Path Function:Write-JsonAtomic -Value {
        param([string]$Path, $Value)
        $script:injectedPairWriteCount++
        if ($script:injectedPairWriteCount -eq 1) {
          [IO.File]::WriteAllText($Path, "new root")
          return
        }
        throw "injected second metadata write failure"
      }

      $rollbackIncomplete = $false
      $errorMessage = $null
      try {
        Write-InstallMetadataPair $Root $Discovery ([ordered]@{ schemaVersion = 1 }) `
          ([ref]$rollbackIncomplete)
      } catch {
        $errorMessage = $_.Exception.Message
      }
      [pscustomobject]@{
        rollback_incomplete = $rollbackIncomplete
        error = $errorMessage
      }
    } $pairRoot $pairDiscovery

    Assert-True ([bool]$pairResult.rollback_incomplete) `
      "Metadata pair did not report its injected rollback failure"
    Assert-True ([string]$pairResult.error -match "install metadata rollback failed") `
      "Metadata pair did not surface its injected rollback failure"
    Assert-True ((Get-Content -LiteralPath $pairRoot -Raw) -ceq "new root") `
      "Metadata pair hid the uncertain committed root bytes"
    Assert-True ((Get-Content -LiteralPath $pairDiscovery -Raw) -ceq "old discovery") `
      "Metadata pair changed discovery while reporting rollback failure"
    Assert-True (Test-Path -LiteralPath $pairBackup -PathType Container) `
      "Metadata pair discarded the recovery backup from its rollback failure"
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-VerifiedTaskCommandSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @(
    "Register-DalaTaskVerified",
    "Remove-DalaTaskVerified",
    "Stop-DalaTaskVerified",
    "Start-DalaTaskVerified",
    "Test-ReleaseTaskRunning"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $scriptText = [IO.File]::ReadAllText($ScriptPath)
  $directRegistrations = [regex]::Matches(
    $scriptText,
    '(?m)^\s+New-DalaTask\s+',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  Assert-True ($directRegistrations.Count -eq 1) `
    "Installer bypasses verified Scheduled Task registration"
  Assert-True ([regex]::IsMatch(
      $scriptText,
      'Get-ScheduledTask\s+-TaskPath\s+"\\"\s+-ErrorAction\s+Stop\s*\|\s*' +
        'Where-Object\s+\{\s*\[string\]\$_\.TaskName\s+-ceq\s+\$Name',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "Installer exact task probe can mistake a query failure for absence"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:fakeTask = $null
      $script:registrationMode = "postcommit"

      Set-Item -Path Function:Get-DalaTaskExact -Value {
        param([string]$Name)
        if ($script:fakeTask -and [string]$script:fakeTask.TaskName -ceq $Name) {
          return $script:fakeTask
        }
        $null
      }
      Set-Item -Path Function:Assert-DalaTaskObjectOwnership -Value {
        param($Task, [string]$Name, [string]$ReleaseDir, [string]$Runner, [string]$LogFile)
        if (-not $Task.owned) { throw "foreign task" }
        $true
      }
      Set-Item -Path Function:New-DalaTask -Value {
        param([string]$Name, [string]$Launcher, [string]$Runner, [string]$LogFile)
        if ($script:registrationMode -eq "absent") { throw "register failed before commit" }
        $owned = $script:registrationMode -ne "foreign"
        $script:fakeTask = [pscustomobject]@{ TaskName = $Name; State = "Ready"; owned = $owned }
        throw "register reported failure after commit"
      }
      Set-Item -Path Function:Stop-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath, $ErrorAction)
        $script:fakeTask.State = "Ready"
        throw "stop reported failure after commit"
      }
      Set-Item -Path Function:Unregister-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath, [switch]$Confirm, $ErrorAction)
        $script:fakeTask = $null
        throw "unregister reported failure after commit"
      }
      Set-Item -Path Function:Start-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath, $ErrorAction)
        $script:fakeTask.State = "Running"
        throw "start reported failure after commit"
      }

      $WarningPreference = "Stop"
      $ambiguous = $false
      Register-DalaTaskVerified "Dala" "launcher" "runner" "log" "release" ([ref]$ambiguous)
      $registeredAfterThrow = $script:fakeTask -and -not $ambiguous

      $script:fakeTask = $null
      $script:registrationMode = "absent"
      $ambiguous = $false
      $absentRejected = $false
      try {
        Register-DalaTaskVerified "Dala" "launcher" "runner" "log" "release" ([ref]$ambiguous)
      } catch {
        $absentRejected = -not $ambiguous -and -not $script:fakeTask
      }

      $script:registrationMode = "foreign"
      $ambiguous = $false
      $foreignRejected = $false
      try {
        Register-DalaTaskVerified "Dala" "launcher" "runner" "log" "release" ([ref]$ambiguous)
      } catch {
        $foreignRejected = $ambiguous -and [bool]$script:fakeTask
      }

      $script:fakeTask = [pscustomobject]@{ TaskName = "Dala"; State = "Running"; owned = $true }
      Stop-DalaTaskVerified "Dala" "release" "runner" "log"
      $stoppedAfterThrow = [string]$script:fakeTask.State -ceq "Ready"

      Start-DalaTaskVerified "Dala" "release" "runner" "log"
      $startedAfterThrow = [string]$script:fakeTask.State -ceq "Running"

      $script:fakeTask.State = "Ready"
      Remove-DalaTaskVerified "Dala" "release" "runner" "log"
      $removedAfterThrow = $null -eq $script:fakeTask

      $script:releaseProcesses = @([pscustomobject]@{ ProcessId = [uint32]42; Count = $null })
      Set-Item -Path Function:Get-ReleaseBeamProcesses -Value { $script:releaseProcesses }
      $script:fakeTask = [pscustomobject]@{
        TaskName = "Dala"
        State = "Queued"
        owned = $true
      }
      $queuedWithBeamAccepted = Test-ReleaseTaskRunning "Dala" "release"
      $script:releaseProcesses = @()
      $queuedWithoutBeamRejected = -not (Test-ReleaseTaskRunning "Dala" "release")
      $script:fakeTask.State = "Ready"
      $script:releaseProcesses = @([pscustomobject]@{ ProcessId = [uint32]43; Count = $null })
      $readyWithBeamRejected = -not (Test-ReleaseTaskRunning "Dala" "release")

      [pscustomobject]@{
        registered_after_throw = $registeredAfterThrow
        absent_unambiguous = $absentRejected
        foreign_ambiguous = $foreignRejected
        stopped_after_throw = $stoppedAfterThrow
        started_after_throw = $startedAfterThrow
        removed_after_throw = $removedAfterThrow
        queued_with_beam_accepted = $queuedWithBeamAccepted
        queued_without_beam_rejected = $queuedWithoutBeamRejected
        ready_with_beam_rejected = $readyWithBeamRejected
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Verified task command smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-VerifiedUpdateTaskCommandSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @(
    "Get-DalaTaskExact",
    "Assert-DalaTaskObjectOwnership",
    "Stop-DalaTaskVerified",
    "Start-DalaTaskVerified",
    "Set-TaskAction",
    "Test-ReleaseTaskRunning"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $scriptText = [IO.File]::ReadAllText($ScriptPath)
  foreach ($command in @("Get-ScheduledTask", "Set-ScheduledTask", "Stop-ScheduledTask", "Start-ScheduledTask")) {
    $calls = [regex]::Matches(
      $scriptText,
      "(?m)^\s+$command\s+",
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Assert-True ($calls.Count -eq 1) `
      "$ScriptPath bypasses verified Scheduled Task handling for $command"
  }
  Assert-True ([regex]::IsMatch(
      $scriptText,
      'Get-ScheduledTask\s+-TaskPath\s+"\\"\s+-ErrorAction\s+Stop\s*\|\s*' +
        'Where-Object\s+\{\s*\[string\]\$_\.TaskName\s+-ceq\s+\$Name',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath exact task probe can mistake a query failure for absence"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:TaskName = "Dala"
      $script:Root = "C:\dala"
      $script:Runner = "C:\dala\run-dala.ps1"
      $script:fakeTask = [pscustomobject]@{ TaskName = "Dala"; State = "Ready"; committed = $false }
      $script:queryFails = $false
      $script:commandMode = "postcommit"

      Set-Item -Path Function:Assert-DalaTaskObjectOwnership -Value {
        param($Task, [string]$ReleaseDir)
        if (-not $Task) { throw "missing fake task" }
        if (-not $Task.committed) { throw "task action was not committed" }
      }
      Set-Item -Path Function:Assert-SafeWritePath -Value {}
      Set-Item -Path Function:Get-ReleaseDirVersion -Value { "1.2.3" }
      Set-Item -Path Function:Get-TaskLauncher -Value { "C:\dala\launcher.exe" }
      Set-Item -Path Function:New-ScheduledTaskAction -Value {
        param([string]$Execute, [string]$Argument)
        [pscustomobject]@{ Execute = $Execute; Arguments = $Argument }
      }
      Set-Item -Path Function:Get-ScheduledTask -Value {
        param([string]$TaskPath)
        if ($script:queryFails) { throw "injected task query failure" }
        @($script:fakeTask)
      }
      Set-Item -Path Function:Set-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath, $Action)
        if ($script:commandMode -eq "postcommit") { $script:fakeTask.committed = $true }
        throw "injected Set-ScheduledTask failure"
      }
      Set-Item -Path Function:Stop-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath)
        if ($script:commandMode -eq "postcommit") { $script:fakeTask.State = "Ready" }
        throw "injected Stop-ScheduledTask failure"
      }
      Set-Item -Path Function:Start-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath)
        if ($script:commandMode -eq "postcommit") { $script:fakeTask.State = "Running" }
        throw "injected Start-ScheduledTask failure"
      }
      Set-Item -Path Function:Start-Sleep -Value {}

      $WarningPreference = "Stop"
      $script:queryFails = $true
      $queryFailureSurfaced = $false
      try { $null = Get-DalaTaskExact "Dala" } catch {
        $queryFailureSurfaced = $_.Exception.Message -match "task query failure"
      }
      $script:queryFails = $false

      Set-TaskAction "target"
      $setPostCommitAccepted = [bool]$script:fakeTask.committed

      $script:commandMode = "precommit"
      $script:fakeTask.committed = $false
      $setPreCommitRejected = $false
      try { Set-TaskAction "target" } catch {
        $setPreCommitRejected = -not [bool]$script:fakeTask.committed
      }

      $script:commandMode = "postcommit"
      $script:fakeTask.committed = $true
      $script:fakeTask.State = "Running"
      Stop-DalaTaskVerified "previous"
      $stopPostCommitAccepted = [string]$script:fakeTask.State -ceq "Ready"
      Start-DalaTaskVerified "target"
      $startPostCommitAccepted = [string]$script:fakeTask.State -ceq "Running"

      $script:commandMode = "precommit"
      $script:fakeTask.State = "Running"
      $stopPreCommitRejected = $false
      try { Stop-DalaTaskVerified "previous" } catch {
        $stopPreCommitRejected = [string]$script:fakeTask.State -ceq "Running"
      }
      $script:fakeTask.State = "Ready"
      $startPreCommitRejected = $false
      try { Start-DalaTaskVerified "target" } catch {
        $startPreCommitRejected = [string]$script:fakeTask.State -ceq "Ready"
      }

      $script:releaseProcesses = @([pscustomobject]@{ ProcessId = [uint32]42; Count = $null })
      Set-Item -Path Function:Get-ReleaseBeamProcesses -Value { $script:releaseProcesses }
      $script:fakeTask.committed = $true
      $script:fakeTask.State = "Queued"
      $queuedWithBeamAccepted = Test-ReleaseTaskRunning "target"
      $script:releaseProcesses = @()
      $queuedWithoutBeamRejected = -not (Test-ReleaseTaskRunning "target")
      $script:fakeTask.State = "Ready"
      $script:releaseProcesses = @([pscustomobject]@{ ProcessId = [uint32]43; Count = $null })
      $readyWithBeamRejected = -not (Test-ReleaseTaskRunning "target")

      [pscustomobject]@{
        query_failure_surfaced = $queryFailureSurfaced
        set_postcommit_accepted = $setPostCommitAccepted
        set_precommit_rejected = $setPreCommitRejected
        stop_postcommit_accepted = $stopPostCommitAccepted
        start_postcommit_accepted = $startPostCommitAccepted
        stop_precommit_rejected = $stopPreCommitRejected
        start_precommit_rejected = $startPreCommitRejected
        queued_with_beam_accepted = $queuedWithBeamAccepted
        queued_without_beam_rejected = $queuedWithoutBeamRejected
        ready_with_beam_rejected = $readyWithBeamRejected
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Verified updater task command smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-InstallerReleaseProcessSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @("Test-ReleaseBootCommand", "Get-ReleaseBeamProcesses")
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $processBody = @($definitions | Where-Object { $_.Name -ceq "Get-ReleaseBeamProcesses" })[0].Extent.Text
  Assert-True ([regex]::IsMatch(
      $processBody,
      'Get-CimInstance\s+Win32_Process[^\r\n]*-ErrorAction\s+Stop',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath process identity query is not fail-closed"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:TagPattern = '^v[0-9]+\.[0-9]+\.[0-9]+$'
      $script:releaseDir = [IO.Path]::Combine(
        [IO.Path]::GetTempPath(),
        "dala-installer-process",
        "v1.2.3"
      )
      $script:expectedExecutable = [IO.Path]::GetFullPath(
        (Join-Path $script:releaseDir "erts-14\bin\erl.exe")
      )
      $script:expectedBoot = [IO.Path]::GetFullPath(
        (Join-Path $script:releaseDir "releases\1.2.3\start")
      )
      $script:expectedBootFile = [IO.Path]::GetFullPath(
        (Join-Path $script:releaseDir "releases\1.2.3\start.boot")
      )
      $script:expectedCleanBoot = [IO.Path]::GetFullPath(
        (Join-Path $script:releaseDir "releases\1.2.3\start_clean")
      )
      $script:expectedCleanBootFile = [IO.Path]::GetFullPath(
        (Join-Path $script:releaseDir "releases\1.2.3\start_clean.boot")
      )
      $script:installerCimFails = $false
      $script:installerCimRows = @()
      $script:installerProcessQueryCount = 0
      $script:installerProcessTransient = $false

      Set-Item -Path Function:Get-Content -Value {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Raw)
        "14 1.2.3"
      }
      Set-Item -Path Function:Get-CimInstance -Value {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        if ($script:installerCimFails) { throw "injected installer CIM query failure" }
        $script:installerProcessQueryCount++
        if ($script:installerProcessTransient -and $script:installerProcessQueryCount -gt 1) {
          return @()
        }
        $script:installerCimRows
      }
      Set-Item -Path Function:Test-SamePath -Value {
        param([string]$Left, [string]$Right)
        $Left -ceq $Right
      }

      $script:installerCimFails = $true
      $queryFailureRejected = $false
      try { $null = @(Get-ReleaseBeamProcesses $script:releaseDir) } catch {
        $queryFailureRejected = $_.Exception.Message -match "installer CIM query failure"
      }

      $script:installerCimFails = $false
      $missingExecutableRejected = $false
      $script:installerCimRows = @([pscustomobject]@{
        ExecutablePath = ""
        CommandLine = "erl.exe -boot `"$($script:expectedBoot)`""
        ProcessId = [uint32]61
      })
      try { $null = @(Get-ReleaseBeamProcesses $script:releaseDir) } catch {
        $missingExecutableRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }

      $missingCommandRejected = $false
      $script:installerCimRows = @([pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = ""
        ProcessId = [uint32]62
      })
      try { $null = @(Get-ReleaseBeamProcesses $script:releaseDir) } catch {
        $missingCommandRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }

      $prefixedBootRejected = $false
      $script:installerCimRows = @([pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = "erl.exe -boot `"$($script:expectedBoot)-foreign`""
        ProcessId = [uint32]63
      })
      $script:installerProcessQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses $script:releaseDir) } catch {
        $prefixedBootRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $prefixedBootRejected = $prefixedBootRejected -and
        $script:installerProcessQueryCount -eq 1

      $prefixedCleanBootRejected = $false
      $script:installerCimRows = @([pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = "erl.exe -boot `"$($script:expectedCleanBoot)-foreign`""
        ProcessId = [uint32]69
      })
      $script:installerProcessQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses $script:releaseDir) } catch {
        $prefixedCleanBootRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $prefixedCleanBootRejected = $prefixedCleanBootRejected -and
        $script:installerProcessQueryCount -eq 1

      $missingPidRejected = $false
      $script:installerCimRows = @([pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = "erl.exe -boot `"$($script:expectedBoot)`""
      })
      try { $null = @(Get-ReleaseBeamProcesses $script:releaseDir) } catch {
        $missingPidRejected = $_.Exception.Message -match "process id.*refusing to continue"
      }

      $validRow = [pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = "erl.exe --boot=`"$($script:expectedBoot)`""
        ProcessId = [uint32]64
      }
      $script:installerCimRows = @($validRow)
      $script:installerProcessQueryCount = 0
      $validRowAccepted = (@(Get-ReleaseBeamProcesses $script:releaseDir).Count -eq 1)

      $startBootFileRow = [pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = '"' + $script:expectedExecutable + '" --boot="' + $script:expectedBootFile + '"'
        ProcessId = [uint32]65
      }
      $script:installerCimRows = @($startBootFileRow)
      $script:installerProcessQueryCount = 0
      $startBootFileAccepted = (@(Get-ReleaseBeamProcesses $script:releaseDir).Count -eq 1)

      $cleanBootRow = [pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = '"' + $script:expectedExecutable + '" -boot "' + $script:expectedCleanBoot + '"'
        ProcessId = [uint32]66
      }
      $script:installerCimRows = @($cleanBootRow)
      $script:installerProcessQueryCount = 0
      $cleanBootAccepted = (@(Get-ReleaseBeamProcesses $script:releaseDir).Count -eq 1)

      $cleanBootFileRow = [pscustomobject]@{
        ExecutablePath = $script:expectedExecutable
        CommandLine = '"' + $script:expectedExecutable + '" --boot="' + $script:expectedCleanBootFile + '"'
        ProcessId = [uint32]67
      }
      $script:installerCimRows = @($cleanBootFileRow)
      $script:installerProcessQueryCount = 0
      $cleanBootFileAccepted = (@(Get-ReleaseBeamProcesses $script:releaseDir).Count -eq 1)

      $script:installerCimRows = @($validRow, $cleanBootRow)
      $script:installerProcessQueryCount = 0
      $mixedServerCleanAccepted = (@(Get-ReleaseBeamProcesses $script:releaseDir).Count -eq 2)

      $foreignEmptyRow = [pscustomobject]@{
        ExecutablePath = "C:\foreign\erl.exe"
        CommandLine = ""
        ProcessId = $null
      }
      $script:installerCimRows = @($foreignEmptyRow)
      $script:installerProcessQueryCount = 0
      $foreignEmptyIgnored = (@(Get-ReleaseBeamProcesses $script:releaseDir).Count -eq 0) -and
        $script:installerProcessQueryCount -eq 1

      $transientIncompleteRow = [pscustomobject]@{
        ExecutablePath = ""
        CommandLine = ""
        ProcessId = [uint32]68
      }
      $script:installerCimRows = @($validRow, $transientIncompleteRow)
      $script:installerProcessQueryCount = 0
      $script:installerProcessTransient = $true
      $transientResult = @(Get-ReleaseBeamProcesses $script:releaseDir)
      $transientFirstSnapshotPidDiscarded = @($transientResult | Where-Object {
        [uint32]$_.ProcessId -eq [uint32]$validRow.ProcessId
      }).Count -eq 0
      $transientIncompleteAccepted = $transientResult.Count -eq 0 -and
        $transientFirstSnapshotPidDiscarded -and
        $script:installerProcessQueryCount -eq 2
      $script:installerProcessTransient = $false

      $script:installerCimRows = @($transientIncompleteRow)
      $script:installerProcessQueryCount = 0
      $persistentIncompleteRejected = $false
      try { $null = @(Get-ReleaseBeamProcesses $script:releaseDir) } catch {
        $persistentIncompleteRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }
      $persistentIncompleteRejected = $persistentIncompleteRejected -and
        $script:installerProcessQueryCount -eq 5

      [pscustomobject]@{
        query_failure_rejected = $queryFailureRejected
        missing_executable_rejected = $missingExecutableRejected
        missing_command_rejected = $missingCommandRejected
        prefixed_boot_rejected = $prefixedBootRejected
        prefixed_clean_boot_rejected = $prefixedCleanBootRejected
        missing_pid_rejected = $missingPidRejected
        valid_row_accepted = $validRowAccepted
        start_boot_file_accepted = $startBootFileAccepted
        clean_boot_accepted = $cleanBootAccepted
        clean_boot_file_accepted = $cleanBootFileAccepted
        mixed_server_clean_accepted = $mixedServerCleanAccepted
        foreign_empty_ignored = $foreignEmptyIgnored
        transient_incomplete_accepted = $transientIncompleteAccepted
        transient_first_snapshot_pid_discarded = $transientFirstSnapshotPidDiscarded
        persistent_incomplete_rejected = $persistentIncompleteRejected
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Installer release process smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-UpdateReleaseProcessSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @(
    "Test-SamePath",
    "Test-ReleaseBootCommand",
    "Invoke-ReleaseWithDefaultEpmdPort",
    "Get-ReleaseBeamProcesses",
    "Get-ReleaseEpmdProcesses",
    "Test-ReleaseEpmdSafeToKill",
    "Get-ReleaseEpmdNames",
    "Invoke-ReleaseEpmdKill",
    "Stop-ReleaseEpmd",
    "Stop-DalaRelease"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }
  Assert-BestEffortReleaseStop $definitions $ScriptPath

  $scriptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptPath).Path)
  Assert-True ([regex]::IsMatch(
      $scriptText,
      'Get-CimInstance\s+Win32_Process[^\r\n]*-ErrorAction\s+Stop',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath process identity query is not fail-closed"
  $stopBody = @($definitions | Where-Object { $_.Name -ceq "Stop-DalaRelease" })[0].Extent.Text
  $killBody = @($definitions | Where-Object { $_.Name -ceq "Invoke-ReleaseEpmdKill" })[0].Extent.Text
  Assert-True ([regex]::IsMatch(
      $stopBody,
      'IsNullOrWhiteSpace\(\$Executable\)[\s\S]*?throw',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath silently accepts an empty release executable"
  Assert-True ([regex]::IsMatch(
      $stopBody,
      'Test-Path\s+-LiteralPath\s+\$Executable[\s\S]*?throw',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath silently accepts a missing release executable"
  Assert-True ([regex]::IsMatch(
      $stopBody,
      'Stop-ReleaseEpmd\s+\$identity\s+\$RequireEpmdStop',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath does not apply its required epmd-stop policy"
  Assert-True ($scriptText -match 'ERL_EPMD_PORT') "$ScriptPath does not isolate the epmd client environment"
  Assert-True ($killBody -match 'Test-ReleaseEpmdSafeToKill') "$ScriptPath does not revalidate epmd safety before kill"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:identity = [pscustomobject]@{
        Executable = "C:\dala\erts-14\bin\erl.exe"
        Epmd = "C:\dala\erts-14\bin\epmd.exe"
        Boot = "C:\dala\releases\1.2.3\start"
        BootFile = "C:\dala\releases\1.2.3\start.boot"
        CleanBoot = "C:\dala\releases\1.2.3\start_clean"
        CleanBootFile = "C:\dala\releases\1.2.3\start_clean.boot"
      }
      $script:rows = @()
      $script:processQueryCount = 0
      $script:processTransient = $false
      $script:epmdRows = @()
      $script:epmdKillPaths = @()
      $script:epmdKillPids = @()
      $script:epmdKillFails = $false
      $script:epmdListenerIds = @()
      $script:epmdNamesOutput = ""
      $script:pathMode = "missing"
      $script:cimFails = $false
      $script:epmdQueryCount = 0
      $script:epmdQueryFailureAfter = -1

      Set-Item -Path Function:Get-ReleaseIdentity -Value {
        param([string]$Executable)
        $script:identity
      }
      Set-Item -Path Function:Test-SamePath -Value {
        param([string]$Left, [string]$Right)
        $Left -ceq $Right
      }
      Set-Item -Path Function:Get-CimInstance -Value {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        if ($script:cimFails) { throw "injected CIM query failure" }
        if ([string]$Filter -match "epmd") {
          $script:epmdQueryCount++
          if ($script:epmdQueryFailureAfter -ge 0 -and
              $script:epmdQueryCount -gt $script:epmdQueryFailureAfter) {
            throw "injected EPMD CIM query failure"
          }
          return $script:epmdRows
        }
        $script:processQueryCount++
        if ($script:processTransient -and $script:processQueryCount -gt 1) {
          return @()
        }
        $script:rows
      }
      Set-Item -Path Function:Get-NetTCPConnection -Value {
        [CmdletBinding()]
        param([string]$State, [int]$LocalPort)
        $script:epmdListenerIds | ForEach-Object {
          [pscustomobject]@{ OwningProcess = [uint32]$_; LocalAddress = "127.0.0.1" }
        }
      }
      Set-Item -Path Function:Get-ReleaseEpmdNames -Value { $script:epmdNamesOutput }
      Set-Item -Path Function:Invoke-ReleaseEpmdKill -Value {
        param([string]$EpmdPath, [uint32]$ExpectedProcessId = 0)
        $script:epmdKillPaths += $EpmdPath
        $script:epmdKillPids += $ExpectedProcessId
        if ($ExpectedProcessId -gt 0 -and @($script:epmdRows | Where-Object {
            [uint32]$_.ProcessId -eq $ExpectedProcessId
          }).Count -ne 1) {
          throw "epmd kill target PID did not match the current process row"
        }
        if (-not $script:epmdKillFails) { $script:epmdRows = @() }
      }
      Set-Item -Path Function:Test-Path -Value {
        [CmdletBinding()]
        param([string]$LiteralPath, $PathType)
        if ($script:pathMode -eq "query-failure") { throw "injected executable query failure" }
        $script:pathMode -eq "present"
      }
      Set-Item -Path Function:Start-Sleep -Value {}
      Set-Item -Path Function:Stop-Process -Value {}

      $unknownFieldsRejected = $false
      $script:rows = @([pscustomobject]@{
        ExecutablePath = ""
        CommandLine = ""
        ProcessId = [uint32]42
      })
      try { $null = @(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat") } catch {
        $unknownFieldsRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }

      $unknownCommandRejected = $false
      $script:rows = @([pscustomobject]@{
        ExecutablePath = [string]$script:identity.Executable
        CommandLine = "erl.exe -boot `"$($script:identity.Boot)-foreign`""
        ProcessId = [uint32]43
      })
      $script:processQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat") } catch {
        $unknownCommandRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $unknownCommandRejected = $unknownCommandRejected -and
        $script:processQueryCount -eq 1

      $unknownCleanCommandRejected = $false
      $script:rows = @([pscustomobject]@{
        ExecutablePath = [string]$script:identity.Executable
        CommandLine = "erl.exe -boot `"$($script:identity.CleanBoot)-foreign`""
        ProcessId = [uint32]49
      })
      $script:processQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat") } catch {
        $unknownCleanCommandRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $unknownCleanCommandRejected = $unknownCleanCommandRejected -and
        $script:processQueryCount -eq 1

      $missingPidRejected = $false
      $script:rows = @([pscustomobject]@{
        ExecutablePath = [string]$script:identity.Executable
        CommandLine = "erl.exe -boot `"$($script:identity.Boot)`""
      })
      try { $null = @(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat") } catch {
        $missingPidRejected = $_.Exception.Message -match "process id.*refusing to continue"
      }

      $validRow = [pscustomobject]@{
        ExecutablePath = [string]$script:identity.Executable
        CommandLine = "erl.exe -boot `"$($script:identity.Boot)`""
        ProcessId = [uint32]44
      }
      $script:rows = @($validRow)
      $script:processQueryCount = 0
      $validRowAccepted = (@(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat").Count -eq 1)

      $startBootFileRow = [pscustomobject]@{
        ExecutablePath = [string]$script:identity.Executable
        CommandLine = '"' + $script:identity.Executable + '" --boot="' + $script:identity.BootFile + '"'
        ProcessId = [uint32]45
      }
      $script:rows = @($startBootFileRow)
      $script:processQueryCount = 0
      $startBootFileAccepted = (@(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat").Count -eq 1)

      $cleanBootRow = [pscustomobject]@{
        ExecutablePath = [string]$script:identity.Executable
        CommandLine = '"' + $script:identity.Executable + '" -boot "' + $script:identity.CleanBoot + '"'
        ProcessId = [uint32]46
      }
      $script:rows = @($cleanBootRow)
      $script:processQueryCount = 0
      $cleanBootAccepted = (@(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat").Count -eq 1)

      $cleanBootFileRow = [pscustomobject]@{
        ExecutablePath = [string]$script:identity.Executable
        CommandLine = '"' + $script:identity.Executable + '" --boot="' + $script:identity.CleanBootFile + '"'
        ProcessId = [uint32]47
      }
      $script:rows = @($cleanBootFileRow)
      $script:processQueryCount = 0
      $cleanBootFileAccepted = (@(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat").Count -eq 1)

      $script:rows = @($validRow, $cleanBootRow)
      $script:processQueryCount = 0
      $mixedServerCleanAccepted = (@(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat").Count -eq 2)

      $foreignEmptyRow = [pscustomobject]@{
        ExecutablePath = "C:\foreign\erl.exe"
        CommandLine = ""
        ProcessId = $null
      }
      $script:rows = @($foreignEmptyRow)
      $script:processQueryCount = 0
      $foreignEmptyIgnored = (@(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat").Count -eq 0) -and
        $script:processQueryCount -eq 1

      $transientIncompleteRow = [pscustomobject]@{
        ExecutablePath = ""
        CommandLine = ""
        ProcessId = [uint32]48
      }
      $script:rows = @($validRow, $transientIncompleteRow)
      $script:processQueryCount = 0
      $script:processTransient = $true
      $transientResult = @(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat")
      $transientFirstSnapshotPidDiscarded = @($transientResult | Where-Object {
        [uint32]$_.ProcessId -eq [uint32]$validRow.ProcessId
      }).Count -eq 0
      $transientIncompleteAccepted = $transientResult.Count -eq 0 -and
        $transientFirstSnapshotPidDiscarded -and
        $script:processQueryCount -eq 2
      $script:processTransient = $false

      $script:rows = @($transientIncompleteRow)
      $script:processQueryCount = 0
      $persistentIncompleteRejected = $false
      try { $null = @(Get-ReleaseBeamProcesses "C:\dala\bin\dala.bat") } catch {
        $persistentIncompleteRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }
      $persistentIncompleteRejected = $persistentIncompleteRejected -and
        $script:processQueryCount -eq 5

      # Reproduce the rollback race where CIM no longer reports epmd.exe but
      # Windows still has its image section open. The stop path must wait for
      # the executable lock instead of treating an empty process query as done.
      $lockedEpmdPath = Join-Path ([IO.Path]::GetTempPath()) `
        ("dala-epmd-lock-" + [guid]::NewGuid().ToString("N") + ".exe")
      [IO.File]::WriteAllText($lockedEpmdPath, "fixture")
      $lockedEpmdHandle = $null
      $lockedEpmdRejected = $false
      $originalEpmdPath = [string]$script:identity.Epmd
      try {
        $lockedEpmdHandle = [IO.File]::Open(
          $lockedEpmdPath,
          [IO.FileMode]::Open,
          [IO.FileAccess]::Read,
          [IO.FileShare]::None
        )
        $script:identity.Epmd = $lockedEpmdPath
        $script:epmdRows = @()
        try { Stop-ReleaseEpmd $script:identity $true } catch {
          $lockedEpmdRejected = $_.Exception.Message -match "epmd did not stop"
        }
      } finally {
        if ($lockedEpmdHandle) { $lockedEpmdHandle.Dispose() }
        $script:identity.Epmd = $originalEpmdPath
        Remove-Item -LiteralPath $lockedEpmdPath -Force -ErrorAction SilentlyContinue
      }

      $script:epmdRows = @(
        [pscustomobject]@{
          ExecutablePath = [string]$script:identity.Epmd
          CommandLine = "epmd.exe -daemon"
          ProcessId = [uint32]71
        },
        [pscustomobject]@{
          ExecutablePath = "C:\foreign\epmd.exe"
          CommandLine = "epmd.exe -daemon"
          ProcessId = [uint32]72
        }
      )
      $epmdMatches = @(Get-ReleaseEpmdProcesses $script:identity)
      $targetEpmdAccepted = $epmdMatches.Count -eq 1 -and
        [string]$epmdMatches[0].ExecutablePath -ceq [string]$script:identity.Epmd
      $foreignEpmdIgnored = @($script:epmdRows | Where-Object {
        [string]$_.ExecutablePath -ceq "C:\foreign\epmd.exe"
      }).Count -eq 1 -and $epmdMatches.Count -eq 1

      $epmdMissingPathRejected = $false
      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = ""
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]73
      })
      try { $null = @(Get-ReleaseEpmdProcesses $script:identity) } catch {
        $epmdMissingPathRejected = $_.Exception.Message -match "identity.*epmd.*refusing to continue"
      }

      # A transient EPMD identity query must retain the daemon in ordinary
      # update mode, while StopOnly/uninstall-style strict mode must fail.
      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = [string]$script:identity.Epmd
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]74
      })
      $script:epmdKillPaths = @()
      $script:epmdListenerIds = @([uint32]74)
      $script:cimFails = $true
      $optionalEpmdQueryFailureAccepted = $false
      $previousWarningPreference = $WarningPreference
      $WarningPreference = "Continue"
      try {
        Stop-ReleaseEpmd $script:identity $false
        $optionalEpmdQueryFailureAccepted = $true
      } finally {
        $WarningPreference = $previousWarningPreference
      }
      $optionalEpmdQueryFailurePreserved = $script:epmdKillPaths.Count -eq 0
      $strictEpmdQueryFailureRejected = $false
      try { Stop-ReleaseEpmd $script:identity $true } catch {
        $strictEpmdQueryFailureRejected = $_.Exception.Message -match "CIM query failure"
      }
      $script:cimFails = $false

      # Exercise the same policy when the daemon disappears between the kill
      # request and the first post-kill identity poll.
      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = [string]$script:identity.Epmd
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]76
      })
      $script:epmdListenerIds = @([uint32]76)
      $script:epmdKillPaths = @()
      $script:epmdKillFails = $true
      $script:epmdQueryCount = 0
      $script:epmdQueryFailureAfter = 1
      $optionalEpmdPollFailureAccepted = $false
      try {
        Stop-ReleaseEpmd $script:identity $false
        $optionalEpmdPollFailureAccepted = $true
      } finally {
        $script:epmdQueryFailureAfter = -1
      }
      $strictEpmdPollFailureRejected = $false
      $script:epmdQueryCount = 0
      $script:epmdQueryFailureAfter = 1
      try { Stop-ReleaseEpmd $script:identity $true } catch {
        $strictEpmdPollFailureRejected = $_.Exception.Message -match "EPMD CIM query failure"
      } finally {
        $script:epmdQueryFailureAfter = -1
      }
      $script:epmdKillFails = $false

      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = [string]$script:identity.Epmd
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]74
      })
      $script:epmdKillPaths = @()
      $script:epmdKillPids = @()
      $script:epmdKillFails = $false
      $script:epmdListenerIds = @([uint32]74)
      $safetyProcess = $script:epmdRows[0]
      $defaultEpmdSafe = Test-ReleaseEpmdSafeToKill $safetyProcess
      $safetyProcess.CommandLine = "epmd.exe -daemon -relaxed_command_check"
      $relaxedEpmdRejected = -not (Test-ReleaseEpmdSafeToKill $safetyProcess)
      $safetyProcess.CommandLine = "epmd.exe -daemon -relaxed_command_check=1"
      $relaxedEqualsEpmdRejected = -not (Test-ReleaseEpmdSafeToKill $safetyProcess)
      $safetyProcess.CommandLine = "epmd.exe -daemon -address 127.0.0.1"
      $addressEpmdRejected = -not (Test-ReleaseEpmdSafeToKill $safetyProcess)
      $safetyProcess.CommandLine = "epmd.exe -daemon -port 4370"
      $customPortEpmdRejected = -not (Test-ReleaseEpmdSafeToKill $safetyProcess)
      $safetyProcess.CommandLine = "epmd.exe -daemon -port foo"
      $malformedPortEpmdRejected = -not (Test-ReleaseEpmdSafeToKill $safetyProcess)
      $safetyProcess.CommandLine = "epmd.exe -daemon"
      $script:epmdListenerIds = @([uint32]999)
      $wrongListenerEpmdRejected = -not (Test-ReleaseEpmdSafeToKill $safetyProcess)
      $script:epmdListenerIds = @([uint32]74)
      Stop-ReleaseEpmd $script:identity $true
      $epmdKillVerified = $script:epmdKillPaths.Count -eq 1 -and
        $script:epmdKillPids.Count -eq 1 -and
        $script:epmdKillPids[0] -eq [uint32]74 -and
        [string]$script:epmdKillPaths[0] -ceq [string]$script:identity.Epmd -and
        @(Get-ReleaseEpmdProcesses $script:identity).Count -eq 0

      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = [string]$script:identity.Epmd
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]75
      })
      $script:epmdListenerIds = @([uint32]75)
      $script:epmdKillFails = $true
      $requiredEpmdFailureRejected = $false
      try { Stop-ReleaseEpmd $script:identity $true } catch {
        $requiredEpmdFailureRejected = $_.Exception.Message -match "epmd did not stop"
      }
      $sharedEpmdPreserved = @(Get-ReleaseEpmdProcesses $script:identity).Count -eq 1
      $optionalEpmdFailureAccepted = $false
      $previousWarningPreference = $WarningPreference
      $WarningPreference = "Continue"
      try {
        Stop-ReleaseEpmd $script:identity $false
        $optionalEpmdFailureAccepted = $true
      } catch {
      } finally {
        $WarningPreference = $previousWarningPreference
      }

      $script:epmdKillFails = $false
      $script:epmdKillPaths = @()
      $script:epmdNamesOutput = "epmd: up and running on port 4369 with data:`nname foreign at port 1234"
      $registeredEpmdPreserved = $false
      try { Stop-ReleaseEpmd $script:identity $true } catch {
        $registeredEpmdPreserved = $_.Exception.Message -match "registered nodes"
      }
      $registeredEpmdPreserved = $registeredEpmdPreserved -and $script:epmdKillPaths.Count -eq 0
      $script:epmdNamesOutput = ""

      $script:pathMode = "present"
      $script:rows = @()
      $script:epmdRows = @()
      $script:rpcAttempted = $false
      Set-Item -Path Function:Invoke-ReleaseWithDefaultEpmdPort -Value {
        param([scriptblock]$Action)
        $script:rpcAttempted = $true
        & $Action
      }
      Stop-DalaRelease "C:\dala\bin\dala.bat"
      $noBeamSkippedRpc = -not $script:rpcAttempted

      $script:pathMode = "missing"
      $emptyExecutableRejected = $false
      try { Stop-DalaRelease "" } catch {
        $emptyExecutableRejected = $_.Exception.Message -match "executable path is empty"
      }
      $missingExecutableRejected = $false
      try { Stop-DalaRelease "C:\dala\bin\dala.bat" } catch {
        $missingExecutableRejected = $_.Exception.Message -match "executable is missing"
      }
      $queryFailureRejected = $false
      $script:pathMode = "query-failure"
      try { Stop-DalaRelease "C:\dala\bin\dala.bat" } catch {
        $queryFailureRejected = $_.Exception.Message -match "executable query failure"
      }

      [pscustomobject]@{
        unknown_fields_rejected = $unknownFieldsRejected
        unknown_command_rejected = $unknownCommandRejected
        unknown_clean_command_rejected = $unknownCleanCommandRejected
        missing_pid_rejected = $missingPidRejected
        valid_row_accepted = $validRowAccepted
        start_boot_file_accepted = $startBootFileAccepted
        clean_boot_accepted = $cleanBootAccepted
        clean_boot_file_accepted = $cleanBootFileAccepted
        mixed_server_clean_accepted = $mixedServerCleanAccepted
        foreign_empty_ignored = $foreignEmptyIgnored
        transient_incomplete_accepted = $transientIncompleteAccepted
        transient_first_snapshot_pid_discarded = $transientFirstSnapshotPidDiscarded
        persistent_incomplete_rejected = $persistentIncompleteRejected
        locked_epmd_without_process_rejected = $lockedEpmdRejected
        target_epmd_accepted = $targetEpmdAccepted
        foreign_epmd_ignored = $foreignEpmdIgnored
        epmd_missing_path_rejected = $epmdMissingPathRejected
        optional_epmd_query_failure_accepted = $optionalEpmdQueryFailureAccepted
        optional_epmd_query_failure_preserved = $optionalEpmdQueryFailurePreserved
        strict_epmd_query_failure_rejected = $strictEpmdQueryFailureRejected
        optional_epmd_poll_failure_accepted = $optionalEpmdPollFailureAccepted
        strict_epmd_poll_failure_rejected = $strictEpmdPollFailureRejected
        epmd_kill_verified = $epmdKillVerified
        required_epmd_failure_rejected = $requiredEpmdFailureRejected
        shared_epmd_preserved = $sharedEpmdPreserved
        optional_epmd_failure_accepted = $optionalEpmdFailureAccepted
        default_epmd_safe = $defaultEpmdSafe
        relaxed_epmd_rejected = $relaxedEpmdRejected
        relaxed_equals_epmd_rejected = $relaxedEqualsEpmdRejected
        address_epmd_rejected = $addressEpmdRejected
        custom_port_epmd_rejected = $customPortEpmdRejected
        malformed_port_epmd_rejected = $malformedPortEpmdRejected
        wrong_listener_epmd_rejected = $wrongListenerEpmdRejected
        registered_epmd_preserved = $registeredEpmdPreserved
        no_beam_skipped_rpc = $noBeamSkippedRpc
        empty_executable_rejected = $emptyExecutableRejected
        missing_executable_rejected = $missingExecutableRejected
        executable_query_failure_rejected = $queryFailureRejected
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Update release process smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-UninstallerVerifiedTaskSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @(
    "Get-DalaTaskExact",
    "Stop-DalaTaskVerified",
    "Remove-DalaTaskVerified"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $scriptText = [IO.File]::ReadAllText($ScriptPath)
  foreach ($command in @("Get-ScheduledTask", "Stop-ScheduledTask", "Unregister-ScheduledTask")) {
    $calls = [regex]::Matches(
      $scriptText,
      "(?m)^\s+$command\s+",
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    Assert-True ($calls.Count -eq 1) `
      "Uninstaller bypasses verified Scheduled Task handling for $command"
  }

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:fakeTask = $null
      $script:queryFails = $false

      Set-Item -Path Function:Get-ScheduledTask -Value {
        param([string]$TaskPath, $ErrorAction)
        if ($script:queryFails) { throw "scheduler query failed" }
        if ($script:fakeTask) { return $script:fakeTask }
        $null
      }
      Set-Item -Path Function:Assert-DalaTaskOwnership -Value {
        param($Task, [string]$InstallRoot)
        if (-not $Task.owned) { throw "foreign task" }
      }
      Set-Item -Path Function:Stop-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath, $ErrorAction)
        $script:fakeTask.State = "Ready"
        throw "stop reported failure after commit"
      }
      Set-Item -Path Function:Unregister-ScheduledTask -Value {
        param([string]$TaskName, [string]$TaskPath, [switch]$Confirm, $ErrorAction)
        $script:fakeTask = $null
        throw "unregister reported failure after commit"
      }

      $script:queryFails = $true
      $queryFailureSurfaced = $false
      try {
        $null = Get-DalaTaskExact "Dala"
      } catch {
        $queryFailureSurfaced = $_.Exception.Message -match "scheduler query failed"
      }

      $WarningPreference = "Stop"
      $script:queryFails = $false
      $script:fakeTask = [pscustomobject]@{ TaskName = "Dala"; State = "Running"; owned = $true }
      Stop-DalaTaskVerified "Dala" "root"
      $stoppedAfterThrow = [string]$script:fakeTask.State -ceq "Ready"

      Remove-DalaTaskVerified "Dala" "root"
      $removedAfterThrow = $null -eq $script:fakeTask

      $script:fakeTask = [pscustomobject]@{ TaskName = "Dala"; State = "Ready"; owned = $false }
      $foreignRejected = $false
      try {
        Remove-DalaTaskVerified "Dala" "root"
      } catch {
        $foreignRejected = $_.Exception.Message -match "foreign task" -and [bool]$script:fakeTask
      }

      [pscustomobject]@{
        query_failure_surfaced = $queryFailureSurfaced
        stopped_after_throw = $stoppedAfterThrow
        removed_after_throw = $removedAfterThrow
        foreign_task_preserved = $foreignRejected
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Uninstaller task command smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-UninstallerFailClosedQuerySemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @(
    "Test-ReleaseBootCommand",
    "Invoke-ReleaseWithDefaultEpmdPort",
    "Get-ReleaseBeamProcesses",
    "Get-ReleaseIdentities",
    "Get-ReleaseEpmdProcesses",
    "Test-ReleaseEpmdSafeToKill",
    "Get-ReleaseEpmdNames",
    "Invoke-ReleaseEpmdKill",
    "Stop-ReleaseEpmd",
    "Stop-DalaRelease",
    "Get-ScopedHolders",
    "Get-ProcessTreeIds",
    "Get-LiveProcessIds",
    "Stop-ScopedHolders"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }
  Assert-BestEffortReleaseStop $definitions $ScriptPath

  foreach ($commandName in @("Get-ChildItem", "Get-CimInstance")) {
    $commands = @(
      $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
          [string]$node.GetCommandName() -ceq $commandName
      }, $true)
    )
    foreach ($command in $commands) {
      Assert-True ([regex]::IsMatch(
          $command.Extent.Text,
          '-ErrorAction\s+Stop',
          [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )) "$ScriptPath query can mistake a $commandName failure for an empty result: $($command.Extent.Text)"
    }
  }

  $scriptText = [IO.File]::ReadAllText($ScriptPath)
  $killBody = @($definitions | Where-Object { $_.Name -ceq "Invoke-ReleaseEpmdKill" })[0].Extent.Text
  $releaseStop = $scriptText.LastIndexOf('Stop-DalaRelease $Root $currentExecutable $true')
  $holderStop = $scriptText.LastIndexOf('$stoppedTerminalPids = @(Stop-ScopedHolders $Root)')
  $firstRemoval = $scriptText.IndexOf('Remove-RequiredPath $target', $holderStop)
  Assert-True ($releaseStop -ge 0 -and $holderStop -gt $releaseStop -and $firstRemoval -gt $holderStop) `
    "$ScriptPath does not complete fail-closed process queries before removing install paths"
  Assert-True ($scriptText -match 'Stop-DalaRelease\s+\$Root\s+\$currentExecutable\s+\$true') `
    "$ScriptPath does not require epmd cleanup before uninstall removal"
  Assert-True ($killBody -match 'Test-ReleaseEpmdSafeToKill') "$ScriptPath does not revalidate epmd safety before kill"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:TagPattern = '^v[0-9]+\.[0-9]+\.[0-9]+$'
      $script:directoryFails = $false
      $script:cimFails = $false
      $script:cimRows = @()
      $script:processQueryCount = 0
      $script:processTransient = $false
      $script:releaseLauncherMissing = $false
      $script:releaseStartDataMissing = $false
      $script:releaseRuntimePresent = $false
      $script:epmdRows = @()
      $script:epmdKillPaths = @()
      $script:epmdKillPids = @()
      $script:epmdKillFails = $false
      $script:epmdListenerIds = @()

      Set-Item -Path Function:Test-Path -Value {
        [CmdletBinding()]
        param([string]$LiteralPath, $PathType)
        $normalizedPath = $LiteralPath.Replace('/', '\')
        if ($script:releaseLauncherMissing -and $normalizedPath -like "*\bin\dala.bat") {
          return $false
        }
        if ($normalizedPath -like "*\releases\start_erl.data") {
          return -not $script:releaseStartDataMissing
        }
        if ($normalizedPath -like "*\erts-14\bin\erl.exe" -or
            $normalizedPath -like "*\erts-14\bin\epmd.exe") {
          return $script:releaseRuntimePresent
        }
        $true
      }
      Set-Item -Path Function:Get-ChildItem -Value {
        [CmdletBinding()]
        param([string]$LiteralPath, [switch]$Directory, [switch]$Force, [string]$Filter)
        if ($script:directoryFails) {
          Write-Error "injected directory query failure"
          return
        }
        $normalizedPath = $LiteralPath.Replace('/', '\')
        if ($normalizedPath -match "versions\\v1\.2\.3$") {
          if ($script:releaseRuntimePresent) {
            [pscustomobject]@{ Name = "erts-14"; FullName = "$LiteralPath\erts-14" }
          }
          return
        }
        [pscustomobject]@{ Name = "v1.2.3"; FullName = "$LiteralPath\v1.2.3" }
      }
      Set-Item -Path Function:Get-ReleaseIdentity -Value {
        [pscustomobject]@{
          Executable = "C:\dala\erl.exe"
          Epmd = "C:\dala\epmd.exe"
          Boot = "C:\dala\start"
          BootFile = "C:\dala\start.boot"
          CleanBoot = "C:\dala\start_clean"
          CleanBootFile = "C:\dala\start_clean.boot"
        }
      }
      Set-Item -Path Function:Get-CimInstance -Value {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        if ($script:cimFails) { Write-Error "injected CIM query failure" }
        if ([string]$Filter -match "epmd") { return $script:epmdRows }
        $script:processQueryCount++
        if ($script:processTransient -and $script:processQueryCount -gt 1) {
          return @()
        }
        $script:cimRows
      }
      Set-Item -Path Function:Get-NetTCPConnection -Value {
        [CmdletBinding()]
        param([string]$State, [int]$LocalPort)
        $script:epmdListenerIds | ForEach-Object {
          [pscustomobject]@{ OwningProcess = [uint32]$_; LocalAddress = "127.0.0.1" }
        }
      }
      Set-Item -Path Function:Get-ReleaseEpmdNames -Value { "" }
      Set-Item -Path Function:Invoke-ReleaseEpmdKill -Value {
        param([string]$EpmdPath, [uint32]$ExpectedProcessId = 0)
        $script:epmdKillPaths += $EpmdPath
        $script:epmdKillPids += $ExpectedProcessId
        if ($ExpectedProcessId -gt 0 -and @($script:epmdRows | Where-Object {
            [uint32]$_.ProcessId -eq $ExpectedProcessId
          }).Count -ne 1) {
          throw "epmd kill target PID did not match the current process row"
        }
        if (-not $script:epmdKillFails) { $script:epmdRows = @() }
      }
      Set-Item -Path Function:Test-SamePath -Value {
        param([string]$Left, [string]$Right)
        $Left -ceq $Right
      }
      Set-Item -Path Function:Stop-Process -Value {}
      Set-Item -Path Function:Get-Process -Value {
        [CmdletBinding()]
        param([uint32]$Id)
        $null
      }
      Set-Item -Path Function:Start-Sleep -Value {}

      $script:directoryFails = $true
      $releaseDirectoryFailureSurfaced = $false
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $releaseDirectoryFailureSurfaced = $_.Exception.Message -match "directory query failure"
      }
      $holderDirectoryFailureSurfaced = $false
      try { $null = @(Get-ScopedHolders "root") } catch {
        $holderDirectoryFailureSurfaced = $_.Exception.Message -match "directory query failure"
      }

      $script:directoryFails = $false
      $script:cimFails = $true
      $releaseCimFailureSurfaced = $false
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $releaseCimFailureSurfaced = $_.Exception.Message -match "CIM query failure"
      }
      $holderCimFailureSurfaced = $false
      try { $null = @(Get-ScopedHolders "root") } catch {
        $holderCimFailureSurfaced = $_.Exception.Message -match "CIM query failure"
      }

      $script:cimFails = $false
      $missingExecutableRejected = $false
      $script:cimRows = @([pscustomobject]@{
        ExecutablePath = ""
        CommandLine = "erl.exe -boot C:\dala\start"
        ProcessId = [uint32]41
      })
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $missingExecutableRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }

      $missingCommandRejected = $false
      $script:cimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = ""
        ProcessId = [uint32]42
      })
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $missingCommandRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }

      $mismatchedBootRejected = $false
      $script:cimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe -boot `"C:\dala\start-foreign`""
        ProcessId = [uint32]43
      })
      $script:processQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $mismatchedBootRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $mismatchedBootRejected = $mismatchedBootRejected -and
        $script:processQueryCount -eq 1

      $mismatchedCleanBootRejected = $false
      $script:cimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe -boot `"C:\dala\start_clean-foreign`""
        ProcessId = [uint32]45
      })
      $script:processQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $mismatchedCleanBootRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $mismatchedCleanBootRejected = $mismatchedCleanBootRejected -and
        $script:processQueryCount -eq 1

      $missingPidRejected = $false
      $script:cimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe -boot C:\dala\start"
      })
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $missingPidRejected = $_.Exception.Message -match "process id.*refusing to continue"
      }

      $validRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe --boot=`"C:\dala\start`""
        ProcessId = [uint32]44
      }
      $script:cimRows = @($validRow)
      $script:processQueryCount = 0
      $validReleaseRowAccepted = (@(Get-ReleaseBeamProcesses "root").Count -eq 1)

      $startBootFileRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = '"C:\dala\erl.exe" --boot="C:\dala\start.boot"'
        ProcessId = [uint32]46
      }
      $script:cimRows = @($startBootFileRow)
      $script:processQueryCount = 0
      $startBootFileAccepted = (@(Get-ReleaseBeamProcesses "root").Count -eq 1)

      $cleanBootRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = '"C:\dala\erl.exe" -boot "C:\dala\start_clean"'
        ProcessId = [uint32]47
      }
      $script:cimRows = @($cleanBootRow)
      $script:processQueryCount = 0
      $cleanBootAccepted = (@(Get-ReleaseBeamProcesses "root").Count -eq 1)

      $cleanBootFileRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = '"C:\dala\erl.exe" --boot="C:\dala\start_clean.boot"'
        ProcessId = [uint32]48
      }
      $script:cimRows = @($cleanBootFileRow)
      $script:processQueryCount = 0
      $cleanBootFileAccepted = (@(Get-ReleaseBeamProcesses "root").Count -eq 1)

      $script:cimRows = @($validRow, $cleanBootRow)
      $script:processQueryCount = 0
      $mixedServerCleanAccepted = (@(Get-ReleaseBeamProcesses "root").Count -eq 2)

      $foreignEmptyRow = [pscustomobject]@{
        ExecutablePath = "C:\foreign\erl.exe"
        CommandLine = ""
        ProcessId = $null
      }
      $script:cimRows = @($foreignEmptyRow)
      $script:processQueryCount = 0
      $foreignEmptyIgnored = (@(Get-ReleaseBeamProcesses "root").Count -eq 0) -and
        $script:processQueryCount -eq 1

      $transientIncompleteRow = [pscustomobject]@{
        ExecutablePath = ""
        CommandLine = ""
        ProcessId = [uint32]49
      }
      $script:cimRows = @($validRow, $transientIncompleteRow)
      $script:processQueryCount = 0
      $script:processTransient = $true
      $transientResult = @(Get-ReleaseBeamProcesses "root")
      $transientFirstSnapshotPidDiscarded = @($transientResult | Where-Object {
        [uint32]$_.ProcessId -eq [uint32]$validRow.ProcessId
      }).Count -eq 0
      $transientIncompleteAccepted = $transientResult.Count -eq 0 -and
        $transientFirstSnapshotPidDiscarded -and
        $script:processQueryCount -eq 2
      $script:processTransient = $false

      $script:cimRows = @($transientIncompleteRow)
      $script:processQueryCount = 0
      $persistentIncompleteRejected = $false
      try { $null = @(Get-ReleaseBeamProcesses "root") } catch {
        $persistentIncompleteRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }
      $persistentIncompleteRejected = $persistentIncompleteRejected -and
        $script:processQueryCount -eq 5

      $identityEnumerationAccepted = @(Get-ReleaseIdentities "root").Count -eq 1
      $script:releaseLauncherMissing = $true
      $missingLauncherWithMarkerAccepted = @(Get-ReleaseIdentities "root").Count -eq 1
      $script:releaseStartDataMissing = $true
      $script:releaseRuntimePresent = $true
      $missingLauncherWithRuntimeAccepted = @(Get-ReleaseIdentities "root").Count -eq 1
      $script:releaseRuntimePresent = $false
      $missingLauncherWithoutMarkersIgnored = @(Get-ReleaseIdentities "root").Count -eq 0
      $script:releaseStartDataMissing = $false
      $script:releaseLauncherMissing = $false
      $script:epmdRows = @(
        [pscustomobject]@{
          ExecutablePath = "C:\dala\epmd.exe"
          CommandLine = "epmd.exe -daemon"
          ProcessId = [uint32]71
        },
        [pscustomobject]@{
          ExecutablePath = "C:\foreign\epmd.exe"
          CommandLine = "epmd.exe -daemon"
          ProcessId = [uint32]72
        }
      )
      $epmdMatches = @(Get-ReleaseEpmdProcesses "root")
      $targetEpmdAccepted = $epmdMatches.Count -eq 1 -and
        [string]$epmdMatches[0].ExecutablePath -ceq "C:\dala\epmd.exe"
      $foreignEpmdIgnored = @($script:epmdRows | Where-Object {
        [string]$_.ExecutablePath -ceq "C:\foreign\epmd.exe"
      }).Count -eq 1 -and $epmdMatches.Count -eq 1

      $epmdMissingPathRejected = $false
      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = ""
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]73
      })
      try { $null = @(Get-ReleaseEpmdProcesses "root") } catch {
        $epmdMissingPathRejected = $_.Exception.Message -match "identity.*epmd.*refusing to continue"
      }

      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\epmd.exe"
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]74
      })
      $script:epmdKillPaths = @()
      $script:epmdKillPids = @()
      $script:epmdKillFails = $false
      $script:epmdListenerIds = @([uint32]74)
      Stop-ReleaseEpmd "root" $true
      $epmdKillVerified = $script:epmdKillPaths.Count -eq 1 -and
        $script:epmdKillPids.Count -eq 1 -and
        $script:epmdKillPids[0] -eq [uint32]74 -and
        [string]$script:epmdKillPaths[0] -ceq "C:\dala\epmd.exe" -and
        @(Get-ReleaseEpmdProcesses "root").Count -eq 0

      $script:epmdRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\epmd.exe"
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]75
      })
      $script:epmdListenerIds = @([uint32]75)
      $script:epmdKillFails = $true
      $requiredEpmdFailureRejected = $false
      try { Stop-ReleaseEpmd "root" $true } catch {
        $requiredEpmdFailureRejected = $_.Exception.Message -match "epmd processes did not stop"
      }
      $sharedEpmdPreserved = @(Get-ReleaseEpmdProcesses "root").Count -eq 1
      $optionalEpmdFailureAccepted = $false
      $previousWarningPreference = $WarningPreference
      $WarningPreference = "Continue"
      try {
        Stop-ReleaseEpmd "root" $false
        $optionalEpmdFailureAccepted = $true
      } catch {
      } finally {
        $WarningPreference = $previousWarningPreference
      }

      $script:cimFails = $true
      $script:holderProbeCount = 0
      Set-Item -Path Function:Get-ScopedHolders -Value {
        $script:holderProbeCount++
        if ($script:holderProbeCount -eq 1) {
          return [pscustomobject]@{ ProcessId = [uint32]123; ParentProcessId = [uint32]1; Count = $null }
        }
        @()
      }
      $snapshotFailureSurfaced = $false
      try { $null = @(Stop-ScopedHolders "root") } catch {
        $snapshotFailureSurfaced = $_.Exception.Message -match "CIM query failure"
      }

      # A single holder is unwrapped to a scalar by Windows PowerShell 5.1;
      # keep its Count property null so this path proves the caller arrays the
      # function result before checking whether cleanup has completed.
      $script:cimFails = $false
      $script:cimRows = @()
      $script:holderProbeCount = 0
      $singleHolderStopAccepted = $false
      try {
        $stoppedHolderIds = @(Stop-ScopedHolders "root")
        $singleHolderStopAccepted = $stoppedHolderIds.Count -eq 1 -and
          [uint32]$stoppedHolderIds[0] -eq [uint32]123
      } catch {
      }

      [pscustomobject]@{
        release_directory_failure_surfaced = $releaseDirectoryFailureSurfaced
        holder_directory_failure_surfaced = $holderDirectoryFailureSurfaced
        release_cim_failure_surfaced = $releaseCimFailureSurfaced
        holder_cim_failure_surfaced = $holderCimFailureSurfaced
        missing_release_executable_rejected = $missingExecutableRejected
        missing_release_command_rejected = $missingCommandRejected
        mismatched_release_boot_rejected = $mismatchedBootRejected
        mismatched_clean_boot_rejected = $mismatchedCleanBootRejected
        missing_release_pid_rejected = $missingPidRejected
        valid_release_row_accepted = $validReleaseRowAccepted
        start_boot_file_accepted = $startBootFileAccepted
        clean_boot_accepted = $cleanBootAccepted
        clean_boot_file_accepted = $cleanBootFileAccepted
        mixed_server_clean_accepted = $mixedServerCleanAccepted
        foreign_empty_ignored = $foreignEmptyIgnored
        transient_incomplete_accepted = $transientIncompleteAccepted
        transient_first_snapshot_pid_discarded = $transientFirstSnapshotPidDiscarded
        persistent_incomplete_rejected = $persistentIncompleteRejected
        identity_enumeration_accepted = $identityEnumerationAccepted
        missing_launcher_with_marker_accepted = $missingLauncherWithMarkerAccepted
        missing_launcher_with_runtime_accepted = $missingLauncherWithRuntimeAccepted
        missing_launcher_without_markers_ignored = $missingLauncherWithoutMarkersIgnored
        target_epmd_accepted = $targetEpmdAccepted
        foreign_epmd_ignored = $foreignEpmdIgnored
        epmd_missing_path_rejected = $epmdMissingPathRejected
        epmd_kill_verified = $epmdKillVerified
        required_epmd_failure_rejected = $requiredEpmdFailureRejected
        shared_epmd_preserved = $sharedEpmdPreserved
        optional_epmd_failure_accepted = $optionalEpmdFailureAccepted
        process_snapshot_failure_surfaced = $snapshotFailureSurfaced
        single_holder_stop_accepted = $singleHolderStopAccepted
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Uninstaller fail-closed query smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-RestartVerifiedTaskSemantics([string]$ScriptPath) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @(
    "Test-SamePath",
    "Test-ReleaseBootCommand",
    "Invoke-ReleaseWithDefaultEpmdPort",
    "Get-ReleaseBeamProcesses",
    "Get-ReleaseEpmdProcesses",
    "Test-ReleaseEpmdSafeToKill",
    "Get-ReleaseEpmdNames",
    "Invoke-ReleaseEpmdKill",
    "Stop-ReleaseEpmd",
    "Stop-DalaRelease",
    "Get-DalaTaskExact",
    "Assert-DalaTaskPrincipal",
    "Assert-DalaTaskOwnership",
    "Test-DalaTaskAction",
    "Set-DalaTaskActionVerified",
    "Stop-DalaTaskVerified",
    "Start-DalaTaskVerified",
    "Restart-DalaTask"
  )
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }
  Assert-BestEffortReleaseStop $definitions $ScriptPath

  $scriptText = [IO.File]::ReadAllText($ScriptPath)
  $killBody = @($definitions | Where-Object { $_.Name -ceq "Invoke-ReleaseEpmdKill" })[0].Extent.Text
  Assert-True (-not [regex]::IsMatch(
      $scriptText,
      '(?:Get-CimInstance|Get-ScheduledTask)[^\r\n]*-ErrorAction\s+SilentlyContinue',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath can mistake a process or task query failure for absence"
  Assert-True ([regex]::IsMatch(
      $scriptText,
      'Get-ScheduledTask\s+-TaskPath\s+"\\"\s+-ErrorAction\s+Stop\s*\|\s*' +
        'Where-Object\s+\{\s*\[string\]\$_\.TaskName\s+-ceq\s+\$Name',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$ScriptPath does not query the root task by exact name"
  Assert-True ($scriptText -match 'Stop-DalaRelease\s+\$Executable\s+\(\[bool\]\$OnlyStop\)') `
    "$ScriptPath does not require epmd cleanup for StopOnly rollback"
  Assert-True ($scriptText -match 'ERL_EPMD_PORT') "$ScriptPath does not isolate the epmd client environment"
  Assert-True ($killBody -match 'Test-ReleaseEpmdSafeToKill') "$ScriptPath does not revalidate epmd safety before kill"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  try {
    $result = & $module {
      $script:fakeTask = $null
      $script:queryFails = $false
      $script:commandMode = "postcommit"
      $script:restartCimFails = $false
      $script:restartCimRows = @()
      $script:restartProcessQueryCount = 0
      $script:restartProcessTransient = $false
      $script:restartEpmdRows = @()
      $script:restartEpmdKillPaths = @()
      $script:restartEpmdKillPids = @()
      $script:restartEpmdListenerIds = @()
      $script:restartPathMode = "missing"

      Set-Item -Path Function:Assert-DalaTaskOwnership -Value {
        param($Task, [string]$InstallRoot)
        if (-not $Task) { throw "missing fake task" }
      }

      Set-Item -Path Function:Get-ReleaseIdentity -Value {
        [pscustomobject]@{
          Executable = "C:\dala\erl.exe"
          Epmd = "C:\dala\epmd.exe"
          Boot = "C:\dala\start"
          BootFile = "C:\dala\start.boot"
          CleanBoot = "C:\dala\start_clean"
          CleanBootFile = "C:\dala\start_clean.boot"
        }
      }
      Set-Item -Path Function:Get-CimInstance -Value {
        [CmdletBinding()]
        param([string]$ClassName, [string]$Filter)
        if ($script:restartCimFails) { Write-Error "injected restart CIM query failure" }
        if ([string]$Filter -match "epmd") { return $script:restartEpmdRows }
        $script:restartProcessQueryCount++
        if ($script:restartProcessTransient -and $script:restartProcessQueryCount -gt 1) {
          return @()
        }
        $script:restartCimRows
      }
      Set-Item -Path Function:Get-NetTCPConnection -Value {
        [CmdletBinding()]
        param([string]$State, [int]$LocalPort)
        $script:restartEpmdListenerIds | ForEach-Object {
          [pscustomobject]@{ OwningProcess = [uint32]$_; LocalAddress = "127.0.0.1" }
        }
      }
      Set-Item -Path Function:Get-ReleaseEpmdNames -Value { "" }
      Set-Item -Path Function:Invoke-ReleaseEpmdKill -Value {
        param([string]$EpmdPath, [uint32]$ExpectedProcessId = 0)
        $script:restartEpmdKillPaths += $EpmdPath
        $script:restartEpmdKillPids += $ExpectedProcessId
        if ($ExpectedProcessId -gt 0 -and @($script:restartEpmdRows | Where-Object {
            [uint32]$_.ProcessId -eq $ExpectedProcessId
          }).Count -ne 1) {
          throw "epmd kill target PID did not match the current process row"
        }
        $script:restartEpmdRows = @()
      }
      Set-Item -Path Function:Test-SamePath -Value {
        param([string]$Left, [string]$Right)
        $Left -ceq $Right
      }
      Set-Item -Path Function:Test-Path -Value {
        [CmdletBinding()]
        param([string]$LiteralPath, $PathType)
        if ($script:restartPathMode -eq "query-failure") {
          throw "injected restart executable query failure"
        }
        $script:restartPathMode -eq "present"
      }
      $script:restartCimFails = $true
      $releaseQueryFailureSurfaced = $false
      try { $null = @(Get-ReleaseBeamProcesses "dala.bat") } catch {
        $releaseQueryFailureSurfaced = $_.Exception.Message -match "restart CIM query failure"
      }

      $script:restartCimFails = $false
      $missingExecutableRejected = $false
      $script:restartCimRows = @([pscustomobject]@{
        ExecutablePath = ""
        CommandLine = "erl.exe -boot C:\dala\start"
        ProcessId = [uint32]51
      })
      try { $null = @(Get-ReleaseBeamProcesses "dala.bat") } catch {
        $missingExecutableRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }

      $missingCommandRejected = $false
      $script:restartCimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = ""
        ProcessId = [uint32]52
      })
      try { $null = @(Get-ReleaseBeamProcesses "dala.bat") } catch {
        $missingCommandRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }

      $mismatchedBootRejected = $false
      $script:restartCimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe -boot `"C:\dala\start-foreign`""
        ProcessId = [uint32]53
      })
      $script:restartProcessQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses "dala.bat") } catch {
        $mismatchedBootRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $mismatchedBootRejected = $mismatchedBootRejected -and
        $script:restartProcessQueryCount -eq 1

      $mismatchedCleanBootRejected = $false
      $script:restartCimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe -boot `"C:\dala\start_clean-foreign`""
        ProcessId = [uint32]55
      })
      $script:restartProcessQueryCount = 0
      try { $null = @(Get-ReleaseBeamProcesses "dala.bat") } catch {
        $mismatchedCleanBootRejected = $_.Exception.Message -match "release identity.*refusing to continue"
      }
      $mismatchedCleanBootRejected = $mismatchedCleanBootRejected -and
        $script:restartProcessQueryCount -eq 1

      $missingPidRejected = $false
      $script:restartCimRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe -boot C:\dala\start"
      })
      try { $null = @(Get-ReleaseBeamProcesses "dala.bat") } catch {
        $missingPidRejected = $_.Exception.Message -match "process id.*refusing to continue"
      }

      $validRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = "erl.exe --boot=`"C:\dala\start`""
        ProcessId = [uint32]54
      }
      $script:restartCimRows = @($validRow)
      $script:restartProcessQueryCount = 0
      $validReleaseRowAccepted = (@(Get-ReleaseBeamProcesses "dala.bat").Count -eq 1)

      $startBootFileRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = '"C:\dala\erl.exe" --boot="C:\dala\start.boot"'
        ProcessId = [uint32]56
      }
      $script:restartCimRows = @($startBootFileRow)
      $script:restartProcessQueryCount = 0
      $startBootFileAccepted = (@(Get-ReleaseBeamProcesses "dala.bat").Count -eq 1)

      $cleanBootRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = '"C:\dala\erl.exe" -boot "C:\dala\start_clean"'
        ProcessId = [uint32]57
      }
      $script:restartCimRows = @($cleanBootRow)
      $script:restartProcessQueryCount = 0
      $cleanBootAccepted = (@(Get-ReleaseBeamProcesses "dala.bat").Count -eq 1)

      $cleanBootFileRow = [pscustomobject]@{
        ExecutablePath = "C:\dala\erl.exe"
        CommandLine = '"C:\dala\erl.exe" --boot="C:\dala\start_clean.boot"'
        ProcessId = [uint32]58
      }
      $script:restartCimRows = @($cleanBootFileRow)
      $script:restartProcessQueryCount = 0
      $cleanBootFileAccepted = (@(Get-ReleaseBeamProcesses "dala.bat").Count -eq 1)

      $script:restartCimRows = @($validRow, $cleanBootRow)
      $script:restartProcessQueryCount = 0
      $mixedServerCleanAccepted = (@(Get-ReleaseBeamProcesses "dala.bat").Count -eq 2)

      $foreignEmptyRow = [pscustomobject]@{
        ExecutablePath = "C:\foreign\erl.exe"
        CommandLine = ""
        ProcessId = $null
      }
      $script:restartCimRows = @($foreignEmptyRow)
      $script:restartProcessQueryCount = 0
      $foreignEmptyIgnored = (@(Get-ReleaseBeamProcesses "dala.bat").Count -eq 0) -and
        $script:restartProcessQueryCount -eq 1

      $transientIncompleteRow = [pscustomobject]@{
        ExecutablePath = ""
        CommandLine = ""
        ProcessId = [uint32]59
      }
      $script:restartCimRows = @($validRow, $transientIncompleteRow)
      $script:restartProcessQueryCount = 0
      $script:restartProcessTransient = $true
      $transientResult = @(Get-ReleaseBeamProcesses "dala.bat")
      $transientFirstSnapshotPidDiscarded = @($transientResult | Where-Object {
        [uint32]$_.ProcessId -eq [uint32]$validRow.ProcessId
      }).Count -eq 0
      $transientIncompleteAccepted = $transientResult.Count -eq 0 -and
        $transientFirstSnapshotPidDiscarded -and
        $script:restartProcessQueryCount -eq 2
      $script:restartProcessTransient = $false

      $script:restartCimRows = @($transientIncompleteRow)
      $script:restartProcessQueryCount = 0
      $persistentIncompleteRejected = $false
      try { $null = @(Get-ReleaseBeamProcesses "dala.bat") } catch {
        $persistentIncompleteRejected = $_.Exception.Message -match "identity.*refusing to continue"
      }
      $persistentIncompleteRejected = $persistentIncompleteRejected -and
        $script:restartProcessQueryCount -eq 5

      $script:restartEpmdRows = @([pscustomobject]@{
        ExecutablePath = "C:\dala\epmd.exe"
        CommandLine = "epmd.exe -daemon"
        ProcessId = [uint32]61
      })
      $script:restartEpmdListenerIds = @([uint32]61)
      $script:restartEpmdKillPaths = @()
      $script:restartEpmdKillPids = @()
      Stop-ReleaseEpmd (Get-ReleaseIdentity "dala.bat") $true
      $epmdKillVerified = $script:restartEpmdKillPaths.Count -eq 1 -and
        $script:restartEpmdKillPids.Count -eq 1 -and
        $script:restartEpmdKillPids[0] -eq [uint32]61 -and
        [string]$script:restartEpmdKillPaths[0] -ceq "C:\dala\epmd.exe" -and
        $script:restartEpmdRows.Count -eq 0

      $emptyExecutableRejected = $false
      try { Stop-DalaRelease "" } catch {
        $emptyExecutableRejected = $_.Exception.Message -match "executable path is empty"
      }
      $missingExecutableFileRejected = $false
      try { Stop-DalaRelease "C:\dala\bin\dala.bat" } catch {
        $missingExecutableFileRejected = $_.Exception.Message -match "executable is missing"
      }
      $script:restartPathMode = "query-failure"
      $executableQueryFailureRejected = $false
      try { Stop-DalaRelease "C:\dala\bin\dala.bat" } catch {
        $executableQueryFailureRejected = $_.Exception.Message -match "restart executable query failure"
      }

      Set-Item -Path Function:Get-ScheduledTask -Value {
        [CmdletBinding()]
        param([string]$TaskPath)
        if ($script:queryFails) { Write-Error "injected task query failure"; return }
        @(
          [pscustomobject]@{ TaskName = "dala"; State = "Ready"; Actions = @() },
          $script:fakeTask
        ) | Where-Object { $null -ne $_ }
      }
      $script:fakeTask = [pscustomobject]@{ TaskName = "Dala"; State = "Ready"; Actions = @() }
      $exactTaskMatched = (Get-DalaTaskExact "Dala") -eq $script:fakeTask
      $lowercaseTaskRejected = $null -eq (Get-DalaTaskExact "DALA")
      $script:queryFails = $true
      $taskQueryFailureSurfaced = $false
      try { $null = Get-DalaTaskExact "Dala" } catch {
        $taskQueryFailureSurfaced = $_.Exception.Message -match "task query failure"
      }

      $script:queryFails = $false
      Set-Item -Path Function:Get-DalaTaskExact -Value {
        if ($script:queryFails) { throw "injected post-command query failure" }
        $script:fakeTask
      }
      Set-Item -Path Function:Set-ScheduledTask -Value {
        [CmdletBinding()]
        param([string]$TaskName, [string]$TaskPath, $Action)
        if ($script:commandMode -eq "postcommit") { $script:fakeTask.Actions = @($Action) }
        throw "injected Set-ScheduledTask failure"
      }
      Set-Item -Path Function:Stop-ScheduledTask -Value {
        [CmdletBinding()]
        param([string]$TaskName, [string]$TaskPath)
        if ($script:commandMode -eq "postcommit") { $script:fakeTask.State = "Ready" }
        throw "injected Stop-ScheduledTask failure"
      }
      Set-Item -Path Function:Start-ScheduledTask -Value {
        [CmdletBinding()]
        param([string]$TaskName, [string]$TaskPath)
        if ($script:commandMode -eq "postcommit") { $script:fakeTask.State = "Running" }
        throw "injected Start-ScheduledTask failure"
      }
      Set-Item -Path Function:Start-Sleep -Value {}

      $WarningPreference = "Stop"
      $expectedAction = [pscustomobject]@{ Execute = "C:\dala\launcher.exe"; Arguments = '"runner" "log"' }
      $script:fakeTask = [pscustomobject]@{ TaskName = "Dala"; State = "Ready"; Actions = @() }
      Set-DalaTaskActionVerified "Dala" $expectedAction
      $setPostCommitAccepted = Test-DalaTaskAction $script:fakeTask $expectedAction

      $script:commandMode = "precommit"
      $script:fakeTask.Actions = @()
      $setPreCommitRejected = $false
      try { Set-DalaTaskActionVerified "Dala" $expectedAction } catch {
        $setPreCommitRejected = @($script:fakeTask.Actions).Count -eq 0
      }

      $script:commandMode = "postcommit"
      $script:fakeTask.State = "Running"
      Stop-DalaTaskVerified "Dala"
      $stopPostCommitAccepted = [string]$script:fakeTask.State -ceq "Ready"
      Start-DalaTaskVerified "Dala"
      $startPostCommitAccepted = [string]$script:fakeTask.State -ceq "Running"

      $script:commandMode = "precommit"
      $script:fakeTask.State = "Running"
      $stopPreCommitRejected = $false
      try { Stop-DalaTaskVerified "Dala" } catch {
        $stopPreCommitRejected = [string]$script:fakeTask.State -ceq "Running"
      }
      $script:fakeTask.State = "Ready"
      $startPreCommitRejected = $false
      try { Start-DalaTaskVerified "Dala" } catch {
        $startPreCommitRejected = [string]$script:fakeTask.State -ceq "Ready"
      }

      $script:setWasCalled = $false
      $script:startWasCalled = $false
      Set-Item -Path Function:Stop-DalaRelease -Value {}
      Set-Item -Path Function:Stop-DalaTaskVerified -Value { throw "injected stop verification failure" }
      Set-Item -Path Function:Set-CurrentTaskAction -Value { $script:setWasCalled = $true }
      Set-Item -Path Function:Start-DalaTaskVerified -Value { $script:startWasCalled = $true }
      $failedStopRejected = $false
      try { Restart-DalaTask "C:\dala\versions\v1.2.3\bin\dala.bat" "Dala" $false } catch {
        $failedStopRejected = $_.Exception.Message -match "stop verification failure"
      }

      [pscustomobject]@{
        release_query_failure_surfaced = $releaseQueryFailureSurfaced
        missing_release_executable_rejected = $missingExecutableRejected
        missing_release_command_rejected = $missingCommandRejected
        mismatched_release_boot_rejected = $mismatchedBootRejected
        mismatched_clean_boot_rejected = $mismatchedCleanBootRejected
        missing_release_pid_rejected = $missingPidRejected
        valid_release_row_accepted = $validReleaseRowAccepted
        start_boot_file_accepted = $startBootFileAccepted
        clean_boot_accepted = $cleanBootAccepted
        clean_boot_file_accepted = $cleanBootFileAccepted
        mixed_server_clean_accepted = $mixedServerCleanAccepted
        foreign_empty_ignored = $foreignEmptyIgnored
        transient_incomplete_accepted = $transientIncompleteAccepted
        transient_first_snapshot_pid_discarded = $transientFirstSnapshotPidDiscarded
        persistent_incomplete_rejected = $persistentIncompleteRejected
        epmd_kill_verified = $epmdKillVerified
        empty_release_executable_rejected = $emptyExecutableRejected
        missing_release_executable_file_rejected = $missingExecutableFileRejected
        release_executable_query_failure_rejected = $executableQueryFailureRejected
        exact_task_matched = $exactTaskMatched
        lowercase_task_rejected = $lowercaseTaskRejected
        task_query_failure_surfaced = $taskQueryFailureSurfaced
        set_postcommit_accepted = $setPostCommitAccepted
        set_precommit_rejected = $setPreCommitRejected
        stop_postcommit_accepted = $stopPostCommitAccepted
        start_postcommit_accepted = $startPostCommitAccepted
        stop_precommit_rejected = $stopPreCommitRejected
        start_precommit_rejected = $startPreCommitRejected
        failed_stop_aborted_restart = $failedStopRejected -and
          -not $script:setWasCalled -and -not $script:startWasCalled
      }
    }

    foreach ($property in $result.PSObject.Properties) {
      Assert-True ([bool]$property.Value) "Restart task command smoke failed: $($property.Name)"
    }
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function ConvertTo-SignedInt32([uint32]$Value) {
  [BitConverter]::ToInt32([BitConverter]::GetBytes($Value), 0)
}

function Write-ExternalAttributeArchive([string]$Path, [uint32]$Attributes) {
  try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch {}
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch {}
  Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue

  $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
  try {
    $entry = $zip.CreateEntry("payload")
    $entry.ExternalAttributes = ConvertTo-SignedInt32 $Attributes
    $stream = $entry.Open()
    try {
      $bytes = [Text.Encoding]::UTF8.GetBytes("payload")
      $stream.Write($bytes, 0, $bytes.Length)
    } finally {
      $stream.Dispose()
    }
  } finally {
    $zip.Dispose()
  }
}

function Write-NamedArchive([string]$Path, [string[]]$Names) {
  try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch {}
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch {}
  Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue

  $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($name in $Names) {
      $entry = $zip.CreateEntry($name)
      $stream = $entry.Open()
      try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("payload")
        $stream.Write($bytes, 0, $bytes.Length)
      } finally {
        $stream.Dispose()
      }
    }
  } finally {
    $zip.Dispose()
  }
}

function Assert-InstallerArchiveTypeSemantics([string]$ScriptPath, [string]$WorkDir) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Assert-SafeArchive"
    }, $true)
  )
  Assert-True ($definitions.Count -eq 1) "$ScriptPath must define exactly one Assert-SafeArchive function"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($definitions[0].Extent.Text))
  $destination = Join-Path $WorkDir "archive type destination"
  New-Item -ItemType Directory -Force -Path $destination | Out-Null

  try {
    $cases = @(
      @{ name = "unix-fifo"; attributes = [uint32]268435456 },
      @{ name = "unix-character-device"; attributes = [uint32]536870912 },
      @{ name = "unix-block-device"; attributes = [uint32]1610612736 },
      @{ name = "unix-symlink"; attributes = [uint32]2684354560 },
      @{ name = "unix-socket"; attributes = [uint32]3221225472 },
      @{ name = "windows-device"; attributes = [uint32]64 },
      @{ name = "windows-reparse"; attributes = [uint32]1024 }
    )
    foreach ($case in $cases) {
      $archive = Join-Path $WorkDir ("$($case.name).zip")
      Write-ExternalAttributeArchive $archive $case.attributes
      $rejected = $false
      try {
        & $module { param($Archive, $Destination) Assert-SafeArchive $Archive $Destination } `
          $archive $destination
      } catch {
        if ($_.Exception.Message -notmatch "special ZIP entry") { throw }
        $rejected = $true
      }
      Assert-True $rejected "Installer accepted $($case.name) ZIP entry"
    }

    $regularArchive = Join-Path $WorkDir "unix-regular.zip"
    Write-ExternalAttributeArchive $regularArchive ([uint32]2175008768)
    & $module { param($Archive, $Destination) Assert-SafeArchive $Archive $Destination } `
      $regularArchive $destination

    $unicodeCollisionArchive = Join-Path $WorkDir "unicode-case-collision.zip"
    Write-NamedArchive $unicodeCollisionArchive @(
      ("safe/" + [char]0x03C3),
      ("SAFE/" + [char]0x03C2),
      ("safe/" + [char]0x1F80),
      ("SAFE/" + [char]0x1F88)
    )
    $collisionRejected = $false
    try {
      & $module { param($Archive, $Destination) Assert-SafeArchive $Archive $Destination } `
        $unicodeCollisionArchive $destination
    } catch {
      if ($_.Exception.Message -notmatch "duplicate ZIP entries") { throw }
      $collisionRejected = $true
    }
    Assert-True $collisionRejected "Installer accepted Unicode case-equivalent ZIP entries"

    $unicodeDistinctArchive = Join-Path $WorkDir "unicode-case-distinct.zip"
    Write-NamedArchive $unicodeDistinctArchive @(
      ("safe/" + [char]0x00DF),
      "safe/SS",
      ("safe/" + [char]0x0130),
      ("safe/i" + [char]0x0307)
    )
    & $module { param($Archive, $Destination) Assert-SafeArchive $Archive $Destination } `
      $unicodeDistinctArchive $destination
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-PublisherSafeRemovalSemantics([string]$ScriptPath, [string]$WorkDir) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $ScriptPath" }

  $requiredFunctions = @("Test-NoReparseAncestors", "Remove-SafePublishTree")
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$ScriptPath must define exactly one $name function"
  }

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  $root = Join-Path $WorkDir "publisher safe removal"
  $victim = Join-Path $WorkDir "publisher removal victim"
  $junction = Join-Path $root "external-junction"
  $sentinel = Join-Path $victim "must-survive.txt"

  New-Item -ItemType Directory -Force -Path $root, $victim | Out-Null
  [IO.File]::WriteAllText($sentinel, "must survive publisher cleanup`n", [Text.UTF8Encoding]::new($false))
  New-Item -ItemType Junction -Path $junction -Target $victim | Out-Null
  try {
    $rejected = $false
    try {
      & $module { param($Path) Remove-SafePublishTree $Path } $root
    } catch {
      if ($_.Exception.Message -notmatch "reparse") { throw }
      $rejected = $true
    }
    Assert-True $rejected "Publisher cleanup followed a junction"
    Assert-True (Test-Path -LiteralPath $sentinel -PathType Leaf) "Publisher cleanup removed an external target"
  } finally {
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    if (Test-Path -LiteralPath $victim) { Remove-Item -LiteralPath $victim -Recurse -Force }
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Get-FreePort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Wait-DalaVersion([int]$Port, [string]$Expected, [int]$TimeoutSeconds = 90) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $uri = "http://127.0.0.1:$Port/version"

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 2 -Uri $uri
      $contentType = [string]$response.Headers["Content-Type"]
      if ($response.StatusCode -eq 200 -and $contentType.StartsWith("text/plain")) {
        $actual = ([string]$response.Content).Trim()
        if ($actual -ceq $Expected) { return }
        if ($actual) { throw "Dala returned version '$actual', expected '$Expected'" }
      }
    } catch {
      if ($_.Exception.Message -like "Dala returned version*") { throw }
    }
    Start-Sleep -Milliseconds 500
  }

  throw "Dala $Expected did not become healthy at $uri"
}

function Get-DalaAppFile([string]$ReleaseDir) {
  $matches = @(
    Get-ChildItem -LiteralPath $ReleaseDir -Filter "dala.app" -Recurse -File |
      Where-Object { $_.FullName -like "*\lib\dala-*\ebin\dala.app" }
  )
  if ($matches.Count -ne 1) { throw "Expected one dala.app in $ReleaseDir, found $($matches.Count)" }
  $matches[0].FullName
}

function Get-DalaAppVersion([string]$ReleaseDir) {
  $appFile = Get-DalaAppFile $ReleaseDir
  $body = Get-Content -LiteralPath $appFile -Raw
  $match = [regex]::Match($body, '\{vsn,\s*"([^"]+)"\}')
  if (-not $match.Success) { throw "Could not read application version from $appFile" }
  $match.Groups[1].Value
}

function Set-DalaAppVersion([string]$ReleaseDir, [string]$Version, [string]$ErlPath) {
  $sourceVersion = Get-DalaAppVersion $ReleaseDir
  if ($sourceVersion -ceq $Version) { return }

  $appFile = Get-DalaAppFile $ReleaseDir
  $sourceAppRoot = Split-Path -Parent (Split-Path -Parent $appFile)
  $targetAppRoot = Join-Path $ReleaseDir "lib\dala-$Version"
  $sourceReleaseRoot = Join-Path $ReleaseDir "releases\$sourceVersion"
  $targetReleaseRoot = Join-Path $ReleaseDir "releases\$Version"
  if (-not (Test-Path -LiteralPath $sourceReleaseRoot -PathType Container)) {
    throw "Release fixture is missing releases\$sourceVersion"
  }
  if ((Test-Path -LiteralPath $targetAppRoot) -or (Test-Path -LiteralPath $targetReleaseRoot)) {
    throw "Release fixture already contains target version $Version"
  }

  $body = Get-Content -LiteralPath $appFile -Raw
  $pattern = [regex]::new('(\{vsn,\s*")([^"]+)("\})')
  if (-not $pattern.IsMatch($body)) { throw "Could not rewrite application version in $appFile" }
  $evaluator = [Text.RegularExpressions.MatchEvaluator]{
    param($match)
    $match.Groups[1].Value + $Version + $match.Groups[3].Value
  }
  $updated = $pattern.Replace($body, $evaluator, 1)
  [IO.File]::WriteAllText($appFile, $updated, [Text.UTF8Encoding]::new($false))

  foreach ($name in @("start.script", "start_clean.script", "dala.rel", "sys.config")) {
    $path = Join-Path $sourceReleaseRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Release fixture is missing $path"
    }
    $contents = Get-Content -LiteralPath $path -Raw
    [IO.File]::WriteAllText($path, $contents.Replace($sourceVersion, $Version), [Text.UTF8Encoding]::new($false))
  }

  $startDataPath = Join-Path $ReleaseDir "releases\start_erl.data"
  $startData = @((Get-Content -LiteralPath $startDataPath -Raw).Trim() -split '\s+')
  if ($startData.Count -ne 2 -or $startData[1] -cne $sourceVersion) {
    throw "Release fixture start_erl.data does not match $sourceVersion"
  }
  [IO.File]::WriteAllText($startDataPath, "$($startData[0]) $Version`n", [Text.UTF8Encoding]::new($false))

  [IO.Directory]::Move($sourceAppRoot, $targetAppRoot)
  [IO.Directory]::Move($sourceReleaseRoot, $targetReleaseRoot)
  Assert-True ((Get-DalaAppVersion $ReleaseDir) -ceq $Version) "dala.app version rewrite did not stick"

  foreach ($scriptName in @("start", "start_clean")) {
    $scriptBase = "releases/$Version/$scriptName"
    $eval = "case systools:script2boot(`"$scriptBase`") of ok -> halt(0); Error -> io:format(standard_error, `"~p~n`", [Error]), halt(1) end."
    Push-Location $ReleaseDir
    try {
      & $ErlPath -noshell -eval $eval
      if ($LASTEXITCODE -ne 0) { throw "Could not rebuild $scriptName.boot for fixture version $Version" }
    } finally {
      Pop-Location
    }
  }
}

function Write-ArchiveChecksum([string]$Archive, [string]$Destination) {
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLowerInvariant()
  $name = Split-Path -Leaf $Archive
  [IO.File]::WriteAllText($Destination, "$hash  $name`n", [Text.UTF8Encoding]::new($false))
}

function Assert-ArchiveChecksum([string]$Archive, [string]$Checksum) {
  $expected = ((Get-Content -LiteralPath $Checksum -Raw).Trim() -split '\s+')[0]
  if ($expected -notmatch '^[0-9A-Fa-f]{64}$') { throw "Malformed smoke input checksum" }
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash
  if ($actual -cne $expected.ToUpperInvariant() -and $actual -cne $expected.ToLowerInvariant()) {
    if ($actual.ToUpperInvariant() -ne $expected.ToUpperInvariant()) {
      throw "Smoke input archive does not match its checksum"
    }
  }
}

function Get-SmokeReleaseVersion([string]$ReleaseDir, [string]$Version) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    $startData = @((Get-Content -LiteralPath (Join-Path $ReleaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
    if ($startData.Count -ne 2) { return $null }
    $Version = [string]$startData[1]
  }
  if ($Version.StartsWith("v", [StringComparison]::Ordinal)) { $Version = $Version.Substring(1) }
  if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { return $null }
  $Version
}

function Get-TaskLauncher([string]$ReleaseDir, [string]$Version) {
  $version = Get-SmokeReleaseVersion $ReleaseDir $Version
  if (-not $version) { return $null }
  $candidate = Join-Path $ReleaseDir "lib\dala-$version\priv\bin\dala_task_launcher.exe"
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
  if (([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
  [IO.Path]::GetFullPath($candidate)
}

function Get-UpdateHelper([string]$ReleaseDir, [string]$Version) {
  $version = Get-SmokeReleaseVersion $ReleaseDir $Version
  if (-not $version) { return $null }
  $candidate = Join-Path $ReleaseDir "lib\dala-$version\priv\windows\update-dala.ps1"
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
  if (([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
  [IO.Path]::GetFullPath($candidate)
}

function Get-SmokeRestartHelper([string]$ReleaseDir, [string]$Version) {
  $version = Get-SmokeReleaseVersion $ReleaseDir $Version
  if (-not $version) { return $null }
  $candidate = Join-Path $ReleaseDir "lib\dala-$version\priv\windows\restart-dala.ps1"
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
  if (([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
  [IO.Path]::GetFullPath($candidate)
}

function Get-PublishHelper([string]$ReleaseDir, [string]$Version) {
  $helper = Join-Path $ReleaseDir "lib\dala-$Version\priv\windows\publish-dala.ps1"
  if (Test-Path -LiteralPath $helper -PathType Leaf) { $helper } else { $null }
}

function Write-PublishFixture([string]$Path, [string]$Version, [string]$Marker, [string]$PublishHelper) {
  $ertsVersion = "16.1.2"
  $bin = Join-Path $Path "bin"
  $release = Join-Path $Path "releases\$Version"
  $ertsBin = Join-Path $Path "erts-$ertsVersion\bin"
  $app = Join-Path $Path "lib\dala-$Version"
  $ebin = Join-Path $app "ebin"
  $privateBin = Join-Path $app "priv\bin"
  $privateWindows = Join-Path $app "priv\windows"
  [IO.Directory]::CreateDirectory($bin) | Out-Null
  [IO.Directory]::CreateDirectory($release) | Out-Null
  [IO.Directory]::CreateDirectory($ertsBin) | Out-Null
  [IO.Directory]::CreateDirectory($ebin) | Out-Null
  [IO.Directory]::CreateDirectory($privateBin) | Out-Null
  [IO.Directory]::CreateDirectory($privateWindows) | Out-Null
  [IO.File]::WriteAllText((Join-Path $bin "dala.bat"), "@echo off`r`n")
  [IO.File]::WriteAllText((Join-Path $Path "run-dala.ps1"), "# fixture`r`n")
  [IO.File]::WriteAllText((Join-Path $Path "releases\start_erl.data"), "$ertsVersion $Version`r`n")
  [IO.File]::WriteAllText((Join-Path $release "start.boot"), "boot")
  [IO.File]::WriteAllText((Join-Path $release "dala.rel"), "release")
  [IO.File]::WriteAllText((Join-Path $ertsBin "erl.exe"), "erl")
  [IO.File]::WriteAllText((Join-Path $ertsBin "epmd.exe"), "epmd")
  [IO.File]::WriteAllText((Join-Path $ebin "dala.app"), "{application,dala,[{vsn,`"$Version`"}]}.`r`n")
  [IO.File]::WriteAllText((Join-Path $ebin "Elixir.Dala.beam"), "beam")
  [IO.File]::WriteAllText((Join-Path $privateBin "dala_task_launcher.exe"), "fixture launcher")
  [IO.File]::WriteAllText((Join-Path $privateWindows "update-dala.ps1"), "# fixture`r`n")
  [IO.File]::WriteAllText((Join-Path $privateWindows "restart-dala.ps1"), "# fixture`r`n")
  Copy-Item -LiteralPath $PublishHelper -Destination (Join-Path $privateWindows "publish-dala.ps1")
  [IO.File]::WriteAllText((Join-Path $Path "publish-marker.txt"), $Marker)
}

function Assert-TaskPrincipal($Task) {
  $expectedSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $userId = [string]$Task.Principal.UserId
  $actualSid = if ($userId -match '^S-[0-9-]+$') {
    [Security.Principal.SecurityIdentifier]::new($userId).Value
  } else {
    ([Security.Principal.NTAccount]::new($userId)).Translate([Security.Principal.SecurityIdentifier]).Value
  }
  Assert-True ($actualSid -ceq $expectedSid) "Scheduled Task principal changed users"
  Assert-True ([string]$Task.Principal.LogonType -ceq "Interactive") "Scheduled Task logon type is not Interactive"
  Assert-True ([string]$Task.Principal.RunLevel -ceq "Limited") "Scheduled Task is unexpectedly elevated"
}

function Assert-TaskAction([string]$TaskName, [string]$Launcher, [string]$Runner, [string]$LogFile) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  Assert-TaskPrincipal $task
  $actions = @($task.Actions)
  Assert-True ($actions.Count -eq 1) "Scheduled Task must have exactly one action"
  Assert-True (Test-SamePath ([string]$actions[0].Execute) $Launcher) "Scheduled Task launcher is not from the expected release"
  $expectedArguments = "`"$Runner`" `"$LogFile`""
  Assert-True ([string]$actions[0].Arguments -ceq $expectedArguments) "Scheduled Task runner arguments changed unexpectedly"
}

function Get-SmokeBeam([string]$InstallRoot) {
  $current = Join-Path $InstallRoot "current.txt"
  if (-not (Test-Path -LiteralPath $current -PathType Leaf)) { return $null }
  $tag = (Get-Content -LiteralPath $current -Raw).Trim()
  if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { return $null }
  $release = Join-Path $InstallRoot "versions\$tag"
  $tokens = @((Get-Content -LiteralPath (Join-Path $release "releases\start_erl.data") -Raw).Trim() -split '\s+')
  if ($tokens.Count -ne 2 -or [string]$tokens[1] -cne $tag.Substring(1)) { return $null }
  $expectedErl = [IO.Path]::GetFullPath((Join-Path $release "erts-$($tokens[0])\bin\erl.exe"))
  $boot = [IO.Path]::GetFullPath((Join-Path $release "releases\$($tokens[1])\start"))
  $processes = @(
    Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction Stop |
      Where-Object {
        $path = [string]$_.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-SamePath $path $expectedErl)) { return $false }
        $command = ([string]$_.CommandLine).Replace('/', '\').Replace('"', '')
        $index = $command.IndexOf($boot, [StringComparison]::OrdinalIgnoreCase)
        if ($index -lt 0) { return $false }
        $prefix = $command.Substring(0, $index).TrimEnd()
        $prefix.EndsWith("-boot", [StringComparison]::OrdinalIgnoreCase) -or
          $prefix.EndsWith("-boot=", [StringComparison]::OrdinalIgnoreCase) -or
          $prefix.EndsWith("--boot", [StringComparison]::OrdinalIgnoreCase) -or
          $prefix.EndsWith("--boot=", [StringComparison]::OrdinalIgnoreCase)
      }
  )
  if ($processes.Count -gt 0) { return $processes[0] }
  $null
}

function Wait-NoSmokeBeam([string]$InstallRoot, [int]$Port = 0) {
  for ($attempt = 0; $attempt -lt 150; $attempt++) {
    if (-not (Get-SmokeBeam $InstallRoot)) { return }
    Start-Sleep -Milliseconds 100
  }
  $beam = $null
  $queryError = $null
  try { $beam = Get-SmokeBeam $InstallRoot } catch { $queryError = $_.Exception.Message }
  $identity = if ($beam) {
    "pid=$($beam.ProcessId); executable=$([string]$beam.ExecutablePath); command=$([string]$beam.CommandLine)"
  } elseif ($queryError) {
    "identity query failed=$queryError"
  } else {
    "identity query returned no matching process"
  }
  if ($Port -gt 0) {
    try {
      $listeners = @(
        Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop |
          ForEach-Object { "address=$($_.LocalAddress); owner=$($_.OwningProcess)" }
      )
      $listenerText = if ($listeners.Count) { $listeners -join "," } else { "none" }
      $identity += "; listeners=$listenerText"
    } catch {
      $identity += "; listener query failed=$($_.Exception.Message)"
    }
  }
  throw "Dala BEAM process did not stop under $InstallRoot ($identity)"
}

function Start-ForeignErl([string]$ReleaseDir, [string]$PathBait) {
  $startData = @((Get-Content -LiteralPath (Join-Path $ReleaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
  if ($startData.Count -ne 2) { throw "Release fixture has malformed start_erl.data: $ReleaseDir" }
  $erl = Join-Path $ReleaseDir "erts-$($startData[0])\bin\erl.exe"
  if (-not (Test-Path -LiteralPath $erl -PathType Leaf)) { $erl = $null }
  if (-not $erl) { throw "Release fixture is missing erl.exe: $ReleaseDir" }

  $arguments = "-noshell -eval `"timer:sleep(600000).`" -extra `"$PathBait`""
  $process = Start-Process -FilePath $erl -ArgumentList $arguments -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 500
  if ($process.HasExited) { throw "Foreign Erl path-boundary fixture exited early" }
  $process
}

function Start-BootedErl([string]$ReleaseDir, [string]$Version, [string]$RuntimeRoot) {
  $startData = @((Get-Content -LiteralPath (Join-Path $ReleaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
  if ($startData.Count -ne 2 -or [string]$startData[1] -cne $Version) {
    throw "Release fixture has malformed start_erl.data: $ReleaseDir"
  }
  $erl = Join-Path $ReleaseDir "erts-$($startData[0])\bin\erl.exe"
  $boot = Join-Path $ReleaseDir "releases\$Version\start_clean"
  $bootFile = "$boot.boot"
  $runtimeRoot = [IO.Path]::GetFullPath($RuntimeRoot)
  $releaseLib = Join-Path $runtimeRoot "lib"
  if (-not (Test-Path -LiteralPath $erl -PathType Leaf) -or
      -not (Test-Path -LiteralPath $bootFile -PathType Leaf) -or
      -not (Test-Path -LiteralPath $releaseLib -PathType Container)) {
    throw "Release fixture is missing boot identity files: $ReleaseDir"
  }

  # start_clean provides a real emulator boot identity without starting Dala.
  $arguments = (
    "-boot `"$boot`" -boot_var ROOT `"$runtimeRoot`" " +
    "-boot_var RELEASE_LIB `"$releaseLib`" -noshell -eval `"timer:sleep(600000).`""
  )
  $process = Start-Process -FilePath $erl -ArgumentList $arguments -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 500
  if ($process.HasExited) { throw "Booted Erl reparse fixture exited early" }
  $process
}

function Write-DummyReleaseRunner([string]$Path, [string]$Tag) {
  $source = @'
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSCommandPath
$releaseDir = Join-Path $root "versions\__TAG__"
$version = ("__TAG__").Substring(1)
$boot = Join-Path $releaseDir "releases\$version\start_clean"
$releaseLib = Join-Path $releaseDir "lib"
$erl = @(
  Get-ChildItem -LiteralPath $releaseDir -Filter "erl.exe" -Recurse -File |
    Where-Object { $_.FullName -like "*\erts-*\bin\erl.exe" }
)
if ($erl.Count -ne 1) { throw "Expected one target erl.exe, found $($erl.Count)" }
# Keep the process idle and unhealthy while exposing a real release identity
# that the fail-closed stop helper can validate before terminating erl.exe.
& $erl[0].FullName -boot "$boot" -boot_var RELEASE_LIB "$releaseLib" `
  -noshell -eval "timer:sleep(600000)."
exit $LASTEXITCODE
'@
  $source = $source.Replace("__TAG__", $Tag)
  [IO.File]::WriteAllText($Path, $source, [Text.UTF8Encoding]::new($false))
}

function Start-VersionDecoy([int]$Port, [string]$Version) {
  $source = @'
$ErrorActionPreference = "Stop"
$port = __PORT__
$version = __VERSION__
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
$listener.Start()
try {
  # A fail-closed identity check may reject the release before it ever probes
  # this foreign listener. Keep the decoy bounded so that cleanup cannot leave
  # a PowerShell process blocked in AcceptTcpClient forever.
  $accept = $listener.AcceptTcpClientAsync()
  if (-not $accept.Wait(30000)) {
    throw "version decoy did not receive a health request within 30 seconds"
  }
  $client = $accept.Result
  try {
    $stream = $client.GetStream()
    $stream.ReadTimeout = 10000
    $buffer = [byte[]]::new(8192)
    $null = $stream.Read($buffer, 0, $buffer.Length)
    $body = [Text.Encoding]::UTF8.GetBytes($version)
    $header = [Text.Encoding]::ASCII.GetBytes(
      "HTTP/1.1 200 OK`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
    )
    $stream.Write($header, 0, $header.Length)
    $stream.Write($body, 0, $body.Length)
    $stream.Flush()
  } finally {
    $client.Dispose()
  }
} finally {
  $listener.Stop()
}
'@
  $source = $source.Replace("__PORT__", [string]$Port)
  $source = $source.Replace("__VERSION__", ($Version | ConvertTo-Json -Compress))
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($source))
  $process = Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-NoProfile -NonInteractive -EncodedCommand $encoded" `
    -WindowStyle Hidden -PassThru

  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if ($process.HasExited) { throw "Version decoy exited before listening on port $Port" }
    $owners = @(
      Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess
    )
    if ($owners -contains [uint32]$process.Id) { return $process }
    Start-Sleep -Milliseconds 100
  }

  Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  throw "Version decoy did not listen on port $Port"
}

function Stop-VersionDecoy($Process) {
  if ($Process -and -not $Process.HasExited) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $Process.Id -Timeout 10 -ErrorAction SilentlyContinue
  }
}

function Stop-SmokeProcesses([string]$Root, [object[]]$KnownProcessIds) {
  $selfPid = [uint32]$PID
  $owned = [Collections.Generic.HashSet[uint32]]::new()
  foreach ($processId in @($KnownProcessIds)) {
    if ($processId -and $processId -ne $selfPid) {
      $owned.Add([uint32]$processId) | Out-Null
    }
  }

  # A scheduled-task wrapper can outlive erl.exe and keep a child console or
  # PowerShell process attached to the smoke tree. Resolve descendants from
  # the unique root-bearing command line before terminating, so unrelated
  # runner processes remain untouched.
  for ($round = 0; $round -lt 20; $round++) {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
      $commandLine = [string]$process.CommandLine
      if ($commandLine -and
          $commandLine.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
          [uint32]$process.ProcessId -ne $selfPid) {
        $owned.Add([uint32]$process.ProcessId) | Out-Null
      }
    }

    $changed = $true
    while ($changed) {
      $changed = $false
      foreach ($process in $processes) {
        if ($owned.Contains([uint32]$process.ParentProcessId) -and
            [uint32]$process.ProcessId -ne $selfPid) {
          $changed = $owned.Add([uint32]$process.ProcessId) -or $changed
        }
      }
    }

    $targets = @(
      $processes |
        Where-Object { $owned.Contains([uint32]$_.ProcessId) } |
        Sort-Object @{ Expression = { [uint32]$_.ParentProcessId }; Descending = $true }
    )
    foreach ($process in $targets) {
      Stop-Process -Id ([uint32]$process.ProcessId) -Force -ErrorAction SilentlyContinue
    }

    $live = @(Get-Process -ErrorAction SilentlyContinue |
      Where-Object { $owned.Contains([uint32]$_.Id) })
    if ($live.Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }
}

function Remove-SmokeTree([string]$Path) {
  try {
    $attributes = [IO.File]::GetAttributes($Path)
  } catch [IO.FileNotFoundException] {
    return
  } catch [IO.DirectoryNotFoundException] {
    return
  }

  if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    # Delete the link itself; never recurse through its target.
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
      [IO.Directory]::Delete($Path)
    } else {
      [IO.File]::Delete($Path)
    }
    return
  }

  if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
      Remove-SmokeTree $entry.FullName
    }
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
    [IO.Directory]::Delete($Path)
  } else {
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
    [IO.File]::Delete($Path)
  }
}

function Wait-VersionDecoyExited($Process, [string]$Label) {
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if ($Process.HasExited) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "$Label did not exit after its one allowed health response"
}

function Assert-NoVisibleConsole([uint32]$BeamPid, [uint32[]]$ExistingOpenConsolePids) {
  $seen = @{}
  $chain = @()
  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$BeamPid"

  while ($process -and -not $seen.ContainsKey([string]$process.ProcessId)) {
    $seen[[string]$process.ProcessId] = $true
    $chain += "$($process.Name):$($process.ProcessId)"
    if ($process.Name -eq "dala_task_launcher.exe") { break }
    if ([uint32]$process.ParentProcessId -eq 0) { break }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)" -ErrorAction SilentlyContinue
  }

  if (-not $process -or $process.Name -ne "dala_task_launcher.exe") {
    throw "Release process chain is not owned by dala_task_launcher.exe: $($chain -join ' <- ')"
  }

  $visibleConsole = Get-CimInstance Win32_Process -Filter "Name='OpenConsole.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $ExistingOpenConsolePids -notcontains [uint32]$_.ProcessId -and
      $_.CommandLine -notmatch '(?:^|\s)--headless(?:\s|$)'
    } |
    Select-Object -First 1
  if ($visibleConsole) {
    throw "Dala created visible console host PID $($visibleConsole.ProcessId): $($visibleConsole.CommandLine)"
  }
}

function Write-InstallMetadata(
  [string]$Path,
  [string]$Root,
  [string]$DataDir,
  [string]$ConfigFile,
  [string]$TaskName,
  [int]$Port,
  [string]$DiscoveryFile
) {
  $metadata = [ordered]@{
    schemaVersion = 1
    root = $Root
    dataDir = $DataDir
    configFile = $ConfigFile
    taskName = $TaskName
    port = $Port
    repo = "mjason/dala"
    platform = "windows-x86_64"
  }
  if (-not [string]::IsNullOrWhiteSpace($DiscoveryFile)) {
    $metadata.discoveryFile = [IO.Path]::GetFullPath($DiscoveryFile)
  }
  $parent = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  [IO.File]::WriteAllText($Path, ($metadata | ConvertTo-Json -Depth 4) + "`n", [Text.UTF8Encoding]::new($false))
}

function Assert-InstallContract(
  [string]$InstallRoot,
  [string]$DataDir,
  [string]$ConfigFile,
  [string]$DiscoveryFile,
  [string]$TaskName,
  [int]$Port
) {
  $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
  Assert-True ($config.server -eq $true) "config.jsonc did not enable the server"
  $configuredPort = [int]$config.port
  Assert-True ($configuredPort -eq $Port) `
    "config.jsonc has the wrong port (actual=$configuredPort expected=$Port): $ConfigFile"
  Assert-True (Test-SamePath ([string]$config.dataDir) $DataDir) "config.jsonc has the wrong dataDir"
  Assert-True (Test-SamePath ([string]$config.releaseRoot) $InstallRoot) "config.jsonc has the wrong releaseRoot"
  Assert-True ([string]$config.serviceName -ceq $TaskName) "config.jsonc has the wrong serviceName"

  foreach ($path in @((Join-Path $InstallRoot "install.json"), $DiscoveryFile)) {
    $metadata = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ([int]$metadata.schemaVersion -eq 1) "install.json has the wrong schemaVersion"
    Assert-True (Test-SamePath ([string]$metadata.root) $InstallRoot) "install.json has the wrong root"
    Assert-True (Test-SamePath ([string]$metadata.dataDir) $DataDir) "install.json has the wrong dataDir"
    Assert-True (Test-SamePath ([string]$metadata.configFile) $ConfigFile) "install.json has the wrong configFile"
    Assert-True ([string]$metadata.taskName -ceq $TaskName) "install.json has the wrong taskName"
    $metadataPort = [int]$metadata.port
    Assert-True ($metadataPort -eq $Port) `
      "install metadata has the wrong port (actual=$metadataPort expected=$Port): $path"
    Assert-True ([string]$metadata.platform -ceq "windows-x86_64") "install.json has the wrong platform"
    Assert-True ($metadata.PSObject.Properties.Name -contains "discoveryFile") `
      "install.json is missing discoveryFile"
    Assert-True (Test-SamePath ([string]$metadata.discoveryFile) $DiscoveryFile) `
      "install.json has the wrong discoveryFile"
  }

  $secretsFile = Join-Path $DataDir "secrets.json"
  $secrets = Get-Content -LiteralPath $secretsFile -Raw | ConvertFrom-Json
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$secrets.secretKeyBase)) "secretKeyBase was not generated"
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$secrets.tokenSigningSecret)) "tokenSigningSecret was not generated"
  Assert-True ([string]$secrets.secretKeyBase -cne [string]$secrets.tokenSigningSecret) "generated secrets must be distinct"

  $nonSecretText = (Get-Content -LiteralPath $ConfigFile -Raw) + (Get-Content -LiteralPath $DiscoveryFile -Raw)
  Assert-True (-not $nonSecretText.Contains([string]$secrets.secretKeyBase)) "secretKeyBase leaked into config or metadata"
  Assert-True (-not $nonSecretText.Contains([string]$secrets.tokenSigningSecret)) "tokenSigningSecret leaked into config or metadata"
}

function Stop-SmokeRelease(
  [string]$TaskName,
  [string]$CurrentExecutable,
  [string]$InstallRoot,
  [int]$Port
) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  $releaseDir = Split-Path -Parent (Split-Path -Parent $CurrentExecutable)
  $restartHelper = Get-SmokeRestartHelper $releaseDir $null
  Assert-True $restartHelper "Release is missing restart-dala.ps1: $releaseDir"
  $stopResults = @(Invoke-SmokeReleaseWithCleanEnvironment {
    $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $restartHelper `
      -TaskName $TaskName -StopOnly -StopExecutable $CurrentExecutable 2>&1 | Out-String
    [pscustomobject]@{
      status = [int]$LASTEXITCODE
      output = $output
    }
  })
  Assert-True ($stopResults.Count -eq 1) "Smoke release stop returned an unexpected result count: $($stopResults.Count)"
  $stopResult = $stopResults[0]
  if ([int]$stopResult.status -ne 0) {
    $details = ([string]$stopResult.output).Trim()
    if ($details) { throw "Smoke release stop failed with exit status $($stopResult.status): $details" }
    throw "Smoke release stop failed with exit status $($stopResult.status)"
  }
  Wait-NoSmokeBeam $InstallRoot $Port
}

function Set-SmokeTaskRunner(
  [string]$TaskName,
  [string]$Launcher,
  [string]$Runner,
  [string]$LogFile,
  [string]$CurrentExecutable,
  [string]$InstallRoot,
  [int]$Port,
  [string]$ExpectedVersion
) {
  Stop-SmokeRelease $TaskName $CurrentExecutable $InstallRoot $Port
  $action = New-ScheduledTaskAction -Execute $Launcher -Argument "`"$Runner`" `"$LogFile`""
  Set-ScheduledTask -TaskName $TaskName -Action $action | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Wait-DalaVersion $Port $ExpectedVersion
}

function Invoke-ReleaseRpc([string]$Executable, [string]$Source) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Source))
  $expression = "Code.eval_string(Base.decode64!(`"$encoded`"))"
  $results = @(Invoke-SmokeReleaseWithCleanEnvironment {
    $output = & $Executable rpc $expression 2>&1 | Out-String
    [pscustomobject]@{
      status = [int]$LASTEXITCODE
      output = $output
    }
  })
  Assert-True ($results.Count -eq 1) "Release RPC returned an unexpected result count: $($results.Count)"
  $result = $results[0]
  if ([int]$result.status -ne 0) { throw "Release RPC failed with exit status $($result.status): $([string]$result.output)" }
}

function Start-DetachedUpdateHelper(
  [string]$Helper,
  [string]$InstallRoot,
  [string]$TaskName,
  [string]$TargetTag,
  [string]$PreviousTag,
  [string]$ExpectedVersion,
  [string]$PreviousVersion,
  [string]$ResultFile,
  [int]$LockTimeoutMilliseconds = -1,
  [Parameter(Mandatory = $true)][string]$AttemptId
) {
  $literal = {
    param([string]$Value)
    "'" + $Value.Replace("'", "''") + "'"
  }
  $command = "& " + (& $literal $Helper) +
    " -InstallRoot " + (& $literal $InstallRoot) +
    " -TaskName " + (& $literal $TaskName) +
    " -TargetTag " + (& $literal $TargetTag) +
    " -PreviousTag " + (& $literal $PreviousTag) +
    " -ExpectedVersion " + (& $literal $ExpectedVersion) +
    " -PreviousVersion " + (& $literal $PreviousVersion) +
    " -AttemptId " + (& $literal $AttemptId) +
    " -ResultFile " + (& $literal $ResultFile) +
    " -HealthTimeoutSeconds 30"
  if ($LockTimeoutMilliseconds -ge 0) {
    $command += " -LockTimeoutMilliseconds $LockTimeoutMilliseconds"
  }
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $commandLine = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
  $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
  $launch = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $commandLine
    ProcessStartupInformation = $startup
  }
  if ($null -eq $launch -or [uint32]$launch.ReturnValue -ne 0) {
    throw "Win32_Process.Create failed for sidebar-style update: $($launch.ReturnValue)"
  }

  [uint32]$launch.ProcessId
}

function Wait-UpdateResult([string]$ResultFile, [string]$AttemptId) {
  for ($attempt = 0; $attempt -lt 600; $attempt++) {
    if (Test-Path -LiteralPath $ResultFile -PathType Leaf) {
      $result = Get-Content -LiteralPath $ResultFile -Raw | ConvertFrom-Json
      Assert-UpdateResultAttempt $result $AttemptId
      return $result
    }
    Start-Sleep -Milliseconds 100
  }
  throw "Detached update helper did not write $ResultFile"
}

function Invoke-DetachedUpdateHelper(
  [string]$Helper,
  [string]$InstallRoot,
  [string]$TaskName,
  [string]$TargetTag,
  [string]$PreviousTag,
  [string]$ExpectedVersion,
  [string]$PreviousVersion,
  [string]$ResultFile,
  [Parameter(Mandatory = $true)][string]$AttemptId
) {
  $null = Start-DetachedUpdateHelper $Helper $InstallRoot $TaskName $TargetTag $PreviousTag `
    $ExpectedVersion $PreviousVersion $ResultFile -AttemptId $AttemptId
  Wait-UpdateResult $ResultFile $AttemptId
}

$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$checksum = (Resolve-Path -LiteralPath $ChecksumPath).Path
$installer = (Resolve-Path -LiteralPath $InstallerScript).Path
$update = (Resolve-Path -LiteralPath $UpdateScript).Path
$uninstall = (Resolve-Path -LiteralPath $UninstallScript).Path
$fixtureErl = (Get-Command erl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$repoRoot = Split-Path -Parent $installer
$updateHelperSource = Join-Path $repoRoot "priv\windows\update-dala.ps1"
$restartHelperSource = Join-Path $repoRoot "priv\windows\restart-dala.ps1"
$publishHelperSource = Join-Path $repoRoot "priv\windows\publish-dala.ps1"
$runSource = Join-Path $repoRoot "priv\windows\run-dala.ps1"

foreach ($script in @($installer, $update, $uninstall, $updateHelperSource, $restartHelperSource, $publishHelperSource, $runSource)) {
  Assert-ScriptParses $script
}
Assert-MetadataFieldCasingSemantics @($installer, $update, $uninstall, $updateHelperSource, $runSource)
Assert-CustomDiscoveryFileNameSemantics @($installer, $update, $uninstall, $updateHelperSource, $runSource)
Assert-InstallMetadataReparseReadSemantics @($installer, $update, $uninstall, $updateHelperSource, $runSource)
foreach ($script in @($installer, $uninstall, $updateHelperSource, $restartHelperSource)) {
  Assert-ReleaseBootCommandSemantics $script
}
Assert-InstallerJsoncSemantics $installer
Assert-ArchiveChecksum $archive $checksum

$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ("dala release smoke " + [guid]::NewGuid().ToString("N"))
$expandedNew = Join-Path $smokeRoot "expanded new"
$expandedOld = Join-Path $smokeRoot "expanded old"
$expandedDecoy = Join-Path $smokeRoot "expanded decoy"
$expandedIncomplete = Join-Path $smokeRoot "expanded incomplete"
$expandedMissingEpmd = Join-Path $smokeRoot "expanded missing epmd"
$expandedStopFailure = Join-Path $smokeRoot "expanded stop failure"
$oldArchive = Join-Path $smokeRoot "dala-old-windows-x86_64.zip"
$oldChecksum = "$oldArchive.sha256"
$decoyArchive = Join-Path $smokeRoot "dala-decoy-windows-x86_64.zip"
$decoyChecksum = "$decoyArchive.sha256"
$stopFailureArchive = Join-Path $smokeRoot "dala-stop-failure-windows-x86_64.zip"
$stopFailureChecksum = "$stopFailureArchive.sha256"
$incompleteArchive = Join-Path $smokeRoot "dala-incomplete-windows-x86_64.zip"
$incompleteChecksum = "$incompleteArchive.sha256"
$missingEpmdArchive = Join-Path $smokeRoot "dala-missing-epmd-windows-x86_64.zip"
$missingEpmdChecksum = "$missingEpmdArchive.sha256"
$installRoot = Join-Path $smokeRoot "install root"
$dataDir = Join-Path $smokeRoot "data dir"
$appDataRoot = Join-Path $smokeRoot "roaming app data"
$discoveryDir = Join-Path $appDataRoot "Dala"
$configDir = Join-Path $smokeRoot "shared config directory"
$configFile = Join-Path $configDir "dala-config.jsonc"
$unrelatedConfigFile = Join-Path $configDir "keep-me.txt"
$scheduledAppData = Join-Path $smokeRoot "scheduled appdata"
$scheduledDiscoveryDir = Join-Path $scheduledAppData "Dala"
$scheduledDiscoveryFile = Join-Path $scheduledDiscoveryDir "install.json"
$scheduledDiscoveryOriginal = "{`"decoy`":true,`"source`":`"scheduled-appdata`"}`n"
$ambientRunnerConfig = Join-Path $smokeRoot "ambient foreign runner config.jsonc"
$discoveryFile = Join-Path $discoveryDir "install.json"
$taskName = "DalaReleaseSmoke-" + [guid]::NewGuid().ToString("N")
$initialPort = [int](Get-FreePort)
# Keep the first installation contract independent from the later port
# migration cases.  PowerShell scripts invoked with the call operator can
# expose variables through dynamic scopes, so a mutable `$port` is not a
# reliable oracle for the recovery assertions below.
$port = $initialPort
$logFile = Join-Path $installRoot "logs\server.log"
$runner = Join-Path $installRoot "run-dala.ps1"
$smokeRunner = Join-Path $installRoot "smoke-runner.ps1"
$resultFile = Join-Path $smokeRoot "holder-result.json"
$sidebarResultFile = Join-Path $smokeRoot "sidebar-update-result.json"
$lockedResultFile = Join-Path $smokeRoot "locked-update-result.json"
$wmiLockedResultFile = Join-Path $smokeRoot "wmi-locked-update-result.json"
$staleResultFile = Join-Path $smokeRoot "stale-update-result.json"
$rollbackCasResultFile = Join-Path $smokeRoot "rollback-cas-result.json"
$restoreResultFile = Join-Path $smokeRoot "restore-after-cas-result.json"
$invalidMetadataResultFile = Join-Path $smokeRoot "invalid-metadata-result.json"
$invalidAttemptResultFile = Join-Path $smokeRoot "invalid-attempt-result.json"
$healthDecoyResultFile = Join-Path $smokeRoot "health-decoy-result.json"
$freshDecoyRoot = Join-Path $smokeRoot "fresh decoy install"
$freshDecoyData = Join-Path $smokeRoot "fresh decoy data"
$freshDecoyAppData = Join-Path $smokeRoot "fresh decoy appdata"
$freshDecoyConfig = Join-Path $smokeRoot "fresh decoy config.jsonc"
$freshDecoyTask = $taskName + "-health-decoy"
$freshDecoyPort = Get-FreePort
while ($freshDecoyPort -eq $initialPort) { $freshDecoyPort = Get-FreePort }
$stopFailureRoot = Join-Path $smokeRoot "stop failure install"
$stopFailureData = Join-Path $smokeRoot "stop failure data"
$stopFailureAppData = Join-Path $smokeRoot "stop failure appdata"
$stopFailureConfig = Join-Path $smokeRoot "stop failure config.jsonc"
$stopFailureTask = $taskName + "-stop-failure"
$stopFailurePort = Get-FreePort
$sessionId = "release-smoke-" + [guid]::NewGuid().ToString("N")
$marker = "DALA_RELEASE_REATTACH_" + [guid]::NewGuid().ToString("N")
$releaseNode = "dala_smoke_" + [guid]::NewGuid().ToString("N") + "@127.0.0.1"
$releaseCookie = "dala_smoke_cookie_" + [guid]::NewGuid().ToString("N")
$secretBait = "DALA_SECRET_BAIT_" + [guid]::NewGuid().ToString("N")
$tokenBait = "DALA_TOKEN_BAIT_" + [guid]::NewGuid().ToString("N")
$holderPid = $null
$shellPid = $null
$foreignTaskName = $null
$foreignUpdateErlPid = $null
$foreignUninstallErlPid = $null
$freshDecoyProcess = $null
$updateDecoyProcess = $null
$reparseErlProcess = $null
$wmiLockPid = $null
$staleLockPid = $null
$summary = $null
$openConsolePidsBefore = @(
  Get-CimInstance Win32_Process -Filter "Name='OpenConsole.exe'" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ProcessId
)

$environmentNames = @(
  "APPDATA", "DALA_HOME", "DALA_DATA_DIR", "DALA_CONFIG", "DALA_DISCOVERY_FILE", "DALA_SERVICE", "DALA_PORT", "DALA_REPO",
  "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET", "DALA_SECRET_KEY_BASE", "DALA_TOKEN_SIGNING_SECRET"
)
$environmentNames += @(Get-SmokeReleaseEnvironmentNames)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
  $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

try {
  New-Item -ItemType Directory -Force -Path $smokeRoot, $expandedNew, $expandedOld, $expandedDecoy, $expandedIncomplete, `
    $expandedMissingEpmd, $expandedStopFailure, $configDir, $scheduledDiscoveryDir | Out-Null
  [IO.File]::WriteAllText($scheduledDiscoveryFile, $scheduledDiscoveryOriginal, [Text.UTF8Encoding]::new($false))
  Assert-InstallerArtifactRollbackSemantics $installer $smokeRoot
  Assert-VerifiedTaskCommandSemantics $installer
  Assert-InstallerReleaseProcessSemantics $installer
  Assert-VerifiedUpdateTaskCommandSemantics $updateHelperSource
  Assert-UpdateReleaseProcessSemantics $updateHelperSource
  Assert-UninstallerVerifiedTaskSemantics $uninstall
  Assert-UninstallerFailClosedQuerySemantics $uninstall
  Assert-UninstallerMissingAppDataSemantics $uninstall $smokeRoot
  Assert-RunnerDiscoveryFallbackSemantics $runSource $smokeRoot
  Assert-RestartVerifiedTaskSemantics $restartHelperSource
  Assert-ReleaseEpmdKillSemantics $updateHelperSource
  Assert-ReleaseEpmdKillSemantics $restartHelperSource
  Assert-ReleaseEpmdKillSemantics $uninstall
  Assert-SmokeReleaseEnvironmentIsolation
  Assert-ReleaseEnvironmentIsolationSemantics $updateHelperSource
  Assert-ReleaseEnvironmentIsolationSemantics $restartHelperSource
  Assert-ReleaseEnvironmentIsolationSemantics $uninstall
  Assert-SmokeLifecycleCommandSemantics $PSCommandPath
  Assert-InstallerArchiveTypeSemantics $installer $smokeRoot
  Assert-PublisherSafeRemovalSemantics $publishHelperSource $smokeRoot
  [IO.File]::WriteAllText($unrelatedConfigFile, "must survive purge`n", [Text.UTF8Encoding]::new($false))
  Expand-Archive -LiteralPath $archive -DestinationPath $expandedNew -Force

  foreach ($required in @("bin\dala.bat", "run-dala.ps1")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $expandedNew $required) -PathType Leaf) "Final ZIP is missing $required"
  }
  Assert-True (Get-TaskLauncher $expandedNew) "Final ZIP is missing dala_task_launcher.exe"
  Assert-True (Get-UpdateHelper $expandedNew) "Final ZIP is missing update-dala.ps1"
  Assert-True (Get-SmokeRestartHelper $expandedNew $null) "Final ZIP is missing restart-dala.ps1"

  $newVersion = Get-DalaAppVersion $expandedNew
  Assert-True (Test-Path -LiteralPath (Join-Path $expandedNew "lib\dala-$newVersion\ebin\Elixir.Dala.beam") -PathType Leaf) "Final ZIP is missing Elixir.Dala.beam"
  Assert-True (Get-PublishHelper $expandedNew $newVersion) "Final ZIP is missing publish-dala.ps1 from the Dala app root"
  $oldVersion = if ($newVersion -ceq "0.0.1") { "0.0.0" } else { "0.0.1" }
  $newTag = "v$newVersion"
  $oldTag = "v$oldVersion"
  $identityRelease = Join-Path $smokeRoot "identity contract\versions\$newTag"
  Write-DalaIdentityFixture $expandedNew $identityRelease $newVersion
  foreach ($identityScript in @($updateHelperSource, $restartHelperSource, $uninstall)) {
    Assert-DalaExecutableIdentity $identityScript $identityRelease $newVersion
  }

  Copy-Item -Path (Join-Path $expandedNew "*") -Destination $expandedIncomplete -Recurse -Force
  Remove-Item -LiteralPath (Join-Path $expandedIncomplete "lib\dala-$newVersion\ebin\Elixir.Dala.beam") -Force
  Compress-Archive -Path (Join-Path $expandedIncomplete "*") -DestinationPath $incompleteArchive -CompressionLevel Optimal
  Write-ArchiveChecksum $incompleteArchive $incompleteChecksum

  $env:APPDATA = Join-Path $smokeRoot "incomplete appdata"
  $env:DALA_HOME = Join-Path $smokeRoot "incomplete install"
  $env:DALA_DATA_DIR = Join-Path $smokeRoot "incomplete data"
  $env:DALA_CONFIG = Join-Path $smokeRoot "incomplete config.jsonc"
  $env:DALA_SERVICE = $taskName + "-incomplete"
  $env:DALA_PORT = [string](Get-FreePort)
  $incompleteOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer `
    -Version $newTag -ArchivePath $incompleteArchive -ChecksumPath $incompleteChecksum `
    -ExpectedVersion $newVersion -HealthTimeoutSeconds 5 2>&1 | Out-String
  $incompleteStatus = $LASTEXITCODE
  Assert-True ($incompleteStatus -ne 0) "Installer accepted a release missing Elixir.Dala.beam"
  Assert-True ($incompleteOutput -match "complete Dala Windows release|Elixir.Dala.beam") "Incomplete release returned an unrelated error"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:DALA_HOME "current.txt"))) "Incomplete release changed current.txt"

  Copy-Item -Path (Join-Path $expandedNew "*") -Destination $expandedMissingEpmd -Recurse -Force
  $missingEpmdStartData = @((Get-Content -LiteralPath (Join-Path $expandedMissingEpmd "releases\start_erl.data") -Raw).Trim() -split '\s+')
  Assert-True ($missingEpmdStartData.Count -eq 2) "Missing-epmd release fixture has malformed start_erl.data"
  Remove-Item -LiteralPath (Join-Path $expandedMissingEpmd "erts-$($missingEpmdStartData[0])\bin\epmd.exe") -Force
  Compress-Archive -Path (Join-Path $expandedMissingEpmd "*") -DestinationPath $missingEpmdArchive -CompressionLevel Optimal
  Write-ArchiveChecksum $missingEpmdArchive $missingEpmdChecksum

  $env:APPDATA = Join-Path $smokeRoot "missing epmd appdata"
  $env:DALA_HOME = Join-Path $smokeRoot "missing epmd install"
  $env:DALA_DATA_DIR = Join-Path $smokeRoot "missing epmd data"
  $env:DALA_CONFIG = Join-Path $smokeRoot "missing epmd config.jsonc"
  $env:DALA_SERVICE = $taskName + "-missing-epmd"
  $env:DALA_PORT = [string](Get-FreePort)
  $missingEpmdOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer `
    -Version $newTag -ArchivePath $missingEpmdArchive -ChecksumPath $missingEpmdChecksum `
    -ExpectedVersion $newVersion -HealthTimeoutSeconds 5 2>&1 | Out-String
  $missingEpmdStatus = $LASTEXITCODE
  Assert-True ($missingEpmdStatus -ne 0) "Installer accepted a release missing epmd.exe"
  Assert-True ($missingEpmdOutput -match "complete Dala Windows release|epmd.exe") "Missing-epmd release returned an unrelated error"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:DALA_HOME "current.txt"))) "Missing-epmd release changed current.txt"

  Copy-Item -Path (Join-Path $expandedNew "*") -Destination $expandedOld -Recurse -Force
  Set-DalaAppVersion $expandedOld $oldVersion $fixtureErl
  Add-Content -LiteralPath (Join-Path $expandedOld "run-dala.ps1") -Value "# old-version runner fixture"
  Compress-Archive -Path (Join-Path $expandedOld "*") -DestinationPath $oldArchive -CompressionLevel Optimal
  Write-ArchiveChecksum $oldArchive $oldChecksum

  Copy-Item -Path (Join-Path $expandedOld "*") -Destination $expandedDecoy -Recurse -Force
  Write-DummyReleaseRunner (Join-Path $expandedDecoy "run-dala.ps1") $oldTag
  Compress-Archive -Path (Join-Path $expandedDecoy "*") -DestinationPath $decoyArchive -CompressionLevel Optimal
  Write-ArchiveChecksum $decoyArchive $decoyChecksum

  Copy-Item -Path (Join-Path $expandedDecoy "*") -Destination $expandedStopFailure -Recurse -Force
  [IO.File]::WriteAllText(
    (Join-Path $expandedStopFailure "run-dala.ps1"),
    "exit 42`r`n",
    [Text.UTF8Encoding]::new($false)
  )
  $stopFailureHelper = Join-Path $expandedStopFailure "lib\dala-$oldVersion\priv\windows\restart-dala.ps1"
  [IO.File]::WriteAllText($stopFailureHelper, "exit 23`r`n", [Text.UTF8Encoding]::new($false))
  Compress-Archive -Path (Join-Path $expandedStopFailure "*") -DestinationPath $stopFailureArchive -CompressionLevel Optimal
  Write-ArchiveChecksum $stopFailureArchive $stopFailureChecksum

  $env:APPDATA = $freshDecoyAppData
  $env:DALA_HOME = $freshDecoyRoot
  $env:DALA_DATA_DIR = $freshDecoyData
  $env:DALA_CONFIG = $freshDecoyConfig
  $env:DALA_SERVICE = $freshDecoyTask
  $env:DALA_PORT = [string]$freshDecoyPort
  $env:DALA_REPO = "mjason/dala"
  $freshStartData = @((Get-Content -LiteralPath (Join-Path $expandedDecoy "releases\start_erl.data") -Raw).Trim() -split '\s+')
  Assert-True ($freshStartData.Count -eq 2) "Fresh health rollback fixture has malformed start_erl.data"
  $freshEpmdPath = [IO.Path]::GetFullPath(
    (Join-Path $freshDecoyRoot "versions\$oldTag\erts-$($freshStartData[0])\bin\epmd.exe")
  )
  $freshDecoyProcess = Start-VersionDecoy $freshDecoyPort $oldVersion
  $freshHealthRejected = $false
  $freshHealthMessage = $null
  $freshDecoyWaitError = $null
  try {
    & $installer -Version $oldTag -ArchivePath $decoyArchive -ChecksumPath $decoyChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 5
  } catch {
    $freshHealthMessage = $_.Exception.Message
    $freshHealthRejected = $true
  } finally {
    try {
      Wait-VersionDecoyExited $freshDecoyProcess "Fresh-install version decoy"
    } catch {
      # A fail-closed installer can legitimately finish without probing the
      # foreign listener. Preserve that installer error for the assertions
      # below; only surface a decoy cleanup failure when the installer itself
      # unexpectedly succeeded.
      $freshDecoyWaitError = $_
    } finally {
      Stop-VersionDecoy $freshDecoyProcess
      $freshDecoyProcess = $null
    }
  }
  if ($freshDecoyWaitError -and -not $freshHealthRejected) {
    throw $freshDecoyWaitError
  }

  $freshTaskLeft = [bool](Get-ScheduledTask -TaskName $freshDecoyTask -ErrorAction SilentlyContinue)
  $freshCurrentLeft = Test-Path -LiteralPath (Join-Path $freshDecoyRoot "current.txt")
  $freshDiscoveryLeft = Test-Path -LiteralPath (Join-Path $freshDecoyAppData "Dala\install.json")
  $freshReleaseLeft = Test-Path -LiteralPath (Join-Path $freshDecoyRoot "versions\$oldTag") -PathType Container
  $freshEpmdLeft = $false
  try {
    Assert-NoOwnedEpmdProcess $freshEpmdPath "Fresh health rollback"
  } catch {
    $freshEpmdLeft = $true
    $freshEpmdError = $_.Exception.Message
  }
  Stop-ScheduledTask -TaskName $freshDecoyTask -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $freshDecoyTask -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine.IndexOf($freshDecoyRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

  Assert-True $freshHealthRejected "Fresh installer accepted a same-version response from a foreign port owner"
  Assert-True ($freshHealthMessage -match "did not become healthy") "Fresh decoy failure returned the wrong error: $freshHealthMessage"
  Assert-True ($freshHealthMessage -notmatch "rollback failed") `
    "Fresh health failure did not complete rollback: $freshHealthMessage"
  Assert-True (-not $freshTaskLeft) "Fresh health rollback left the Scheduled Task behind: $freshHealthMessage"
  Assert-True (-not $freshCurrentLeft) "Fresh health rollback left current.txt behind"
  Assert-True (-not $freshDiscoveryLeft) "Fresh health rollback left discovery metadata behind"
  Assert-True (-not $freshReleaseLeft) "Fresh health rollback left the installed release tree behind"
  Assert-True (-not $freshEpmdLeft) "Fresh health rollback left release-owned epmd.exe running: $freshEpmdPath ($freshEpmdError)"
  Remove-Item -LiteralPath $freshDecoyRoot, $freshDecoyData, $freshDecoyAppData, $freshDecoyConfig `
    -Recurse -Force -ErrorAction SilentlyContinue

  $env:APPDATA = $stopFailureAppData
  $env:DALA_HOME = $stopFailureRoot
  $env:DALA_DATA_DIR = $stopFailureData
  $env:DALA_CONFIG = $stopFailureConfig
  $env:DALA_SERVICE = $stopFailureTask
  $env:DALA_PORT = [string]$stopFailurePort
  $stopFailureRejected = $false
  $stopFailureMessage = $null
  try {
    & $installer -Version $oldTag -ArchivePath $stopFailureArchive -ChecksumPath $stopFailureChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 2
  } catch {
    $stopFailureMessage = $_.Exception.Message
    $stopFailureRejected = $true
  }
  Assert-True $stopFailureRejected "Fresh rollback ignored a failing release stop helper"
  Assert-True ($stopFailureMessage -match "release stop rollback failed with exit status 23") `
    "Fresh rollback returned the wrong stop-helper error: $stopFailureMessage"
  $preservedStopFailureTask = Get-ScheduledTask -TaskName $stopFailureTask -TaskPath "\" -ErrorAction SilentlyContinue
  Assert-True $preservedStopFailureTask "Failed release stop removed the Scheduled Task"
  Assert-True ([string]$preservedStopFailureTask.State -notin @("Running", "Queued")) `
    "Immediate task exit was still active during stop-helper rollback"
  Assert-True (((Get-Content -LiteralPath (Join-Path $stopFailureRoot "current.txt") -Raw).Trim()) -ceq $oldTag) `
    "Failed release stop removed current.txt"
  Assert-True (Test-Path -LiteralPath (Join-Path $stopFailureRoot "versions\$oldTag") -PathType Container) `
    "Failed release stop removed the release"
  Assert-True (Test-Path -LiteralPath (Join-Path $stopFailureRoot "install.json") -PathType Leaf) `
    "Failed release stop removed install metadata"
  Stop-ScheduledTask -TaskName $stopFailureTask -TaskPath "\" -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $stopFailureTask -TaskPath "\" -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$stopFailureRoot*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $stopFailureRoot, $stopFailureData, $stopFailureAppData, $stopFailureConfig `
    -Recurse -Force -ErrorAction SilentlyContinue

  $env:APPDATA = $appDataRoot
  $env:DALA_HOME = $installRoot
  $env:DALA_DATA_DIR = $dataDir
  $env:DALA_CONFIG = $configFile
  $env:DALA_SERVICE = $taskName
  $env:DALA_PORT = [string]$initialPort
  $env:DALA_REPO = "mjason/dala"
  $env:RELEASE_NODE = $releaseNode
  $env:RELEASE_COOKIE = $releaseCookie

  New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $installRoot ".dala-install"), "Dala installation root`n")
  $crossRoot = Join-Path $smokeRoot "cross-root locked install"
  $crossData = Join-Path $smokeRoot "cross-root locked data"
  $crossAppData = Join-Path $smokeRoot "cross-root locked appdata"
  $crossConfig = Join-Path $smokeRoot "cross-root locked config.jsonc"
  New-Item -ItemType Directory -Force -Path (Join-Path $crossAppData "Dala") | Out-Null
  [IO.File]::WriteAllText((Join-Path $crossAppData "Dala\install.json"), "{invalid metadata")
  $freshLock = Enter-SmokeLifecycleMutex
  try {
    $lockedInstallOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer `
      -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 30 2>&1 | Out-String
    $lockedInstallStatus = $LASTEXITCODE

    try {
      $env:APPDATA = $crossAppData
      $env:DALA_HOME = $crossRoot
      $env:DALA_DATA_DIR = $crossData
      $env:DALA_CONFIG = $crossConfig
      $crossLockedOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer `
        -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
        -ExpectedVersion $oldVersion -HealthTimeoutSeconds 30 2>&1 | Out-String
      $crossLockedStatus = $LASTEXITCODE
    } finally {
      $env:APPDATA = $appDataRoot
      $env:DALA_HOME = $installRoot
      $env:DALA_DATA_DIR = $dataDir
      $env:DALA_CONFIG = $configFile
    }
  } finally {
    Exit-SmokeLifecycleMutex $freshLock
  }
  Assert-True ($lockedInstallStatus -ne 0) "Fresh installer ignored the lifecycle lock"
  Assert-True ($lockedInstallOutput -match "already in progress") "Fresh installer returned the wrong lock error"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installRoot "current.txt"))) "Locked fresh installer changed current.txt"
  Assert-True (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) "Locked fresh installer created a task"
  Assert-True ($crossLockedStatus -ne 0) "Cross-root installer ignored the global lifecycle mutex"
  Assert-True ($crossLockedOutput -match "already in progress") "Cross-root lock was acquired after reading malformed metadata"
  Assert-True (-not (Test-Path -LiteralPath $crossRoot)) "Cross-root lock loser changed its installation root"

  $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $collisionAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command exit"
  $collisionTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
  $collisionSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
  $collisionPrincipal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $collisionAction -Trigger $collisionTrigger `
    -Settings $collisionSettings -Principal $collisionPrincipal | Out-Null
  $collisionOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer `
    -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
    -ExpectedVersion $oldVersion -HealthTimeoutSeconds 30 2>&1 | Out-String
  $collisionStatus = $LASTEXITCODE
  Assert-True ($collisionStatus -ne 0) "Fresh installer overwrote an existing task name"
  Assert-True ($collisionOutput -match "already exists") "Task-name collision returned the wrong error"
  $collisionTask = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  Assert-True ([string]$collisionTask.Actions[0].Execute -ceq "powershell.exe") "Fresh installer replaced the foreign task"
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false

  & $installer -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
    -ExpectedVersion $oldVersion -HealthTimeoutSeconds 90
  Wait-DalaVersion $initialPort $oldVersion

  $oldDir = Join-Path $installRoot "versions\$oldTag"
  $oldBatch = Join-Path $oldDir "bin\dala.bat"
  $oldLauncher = Get-TaskLauncher $oldDir
  Assert-True $oldLauncher "Installed old release is missing dala_task_launcher.exe"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Assert-InstallContract $installRoot $dataDir $configFile $discoveryFile $taskName $initialPort
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $configDir ".dala-config"))) "Installer claimed a shared config directory"
  Assert-True (Test-Path -LiteralPath $unrelatedConfigFile -PathType Leaf) "Installer modified the shared config directory"

  $rootMetadataFile = Join-Path $installRoot "install.json"
  $rootMetadataText = Get-Content -LiteralPath $rootMetadataFile -Raw
  $discoveryMetadataText = Get-Content -LiteralPath $discoveryFile -Raw
  $configText = Get-Content -LiteralPath $configFile -Raw
  $unrelatedConfigBackup = Join-Path $smokeRoot "rollback keep-me.txt"
  $configMarker = Join-Path $configDir ".dala-config"
  Move-Item -LiteralPath $unrelatedConfigFile -Destination $unrelatedConfigBackup
  Remove-Item -LiteralPath $configFile, $discoveryFile -Force
  New-Item -ItemType Directory -Path $discoveryFile | Out-Null
  try {
    # Keep this expected failure inside a child PowerShell so its nonzero exit
    # and rendered error can be asserted without terminating the smoke test.
    $precommitOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer `
      -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 30 2>&1 | Out-String
    $precommitStatus = $LASTEXITCODE
    Assert-True ($precommitStatus -ne 0 -and
      $precommitOutput -match "(?:metadata target is not|discoveryFile must be) a regular file") `
      "Existing installer accepted a directory metadata target: $precommitOutput"
    Assert-True (-not (Test-Path -LiteralPath $configFile)) `
      "Existing install failure left the config created by this attempt"
    Assert-True (-not (Test-Path -LiteralPath $configMarker)) `
      "Existing install failure left the config ownership marker created by this attempt"
    Assert-True ((Get-Content -LiteralPath $rootMetadataFile -Raw) -ceq $rootMetadataText) `
      "Existing install failure changed original root metadata before commit"
    Assert-True (Test-Path -LiteralPath $discoveryFile -PathType Container) `
      "Existing install failure removed the original non-file discovery target"
    Assert-TaskAction $taskName $oldLauncher $runner $logFile
  } finally {
    Remove-Item -LiteralPath $configFile, $configMarker -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $discoveryFile) {
      Remove-Item -LiteralPath $discoveryFile -Recurse -Force
    }
    [IO.File]::WriteAllText($rootMetadataFile, $rootMetadataText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($discoveryFile, $discoveryMetadataText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($configFile, $configText, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $unrelatedConfigBackup -PathType Leaf) {
      Move-Item -LiteralPath $unrelatedConfigBackup -Destination $unrelatedConfigFile
    }
  }

  Remove-Item -LiteralPath $discoveryFile -Force
  try {
    & $installer -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 90
  } catch {
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath "\" -ErrorAction SilentlyContinue
    if ($task) {
      Write-Warning "Same-version recovery task state: $([string]$task.State)"
    }
    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath "\" -ErrorAction SilentlyContinue
    if ($taskInfo) {
      Write-Warning "Same-version recovery task result: $($taskInfo.LastTaskResult)"
    }
    if (Test-Path -LiteralPath $logFile -PathType Leaf) {
      Write-Warning "Same-version recovery server.log tail follows"
      Get-Content -LiteralPath $logFile -Tail 200 | Write-Warning
    }
    Write-SmokeReleaseProcessSnapshot "Same-version recovery" $oldDir $smokeRoot $initialPort
    throw
  }
  Assert-True (Test-Path -LiteralPath $discoveryFile -PathType Leaf) "Installer did not recover missing discovery metadata"
  Assert-InstallContract $installRoot $dataDir $configFile $discoveryFile $taskName $initialPort

  $mismatchedMetadata = $rootMetadataText | ConvertFrom-Json
  $mismatchedMetadata.port = $initialPort + 1
  [IO.File]::WriteAllText($discoveryFile, ($mismatchedMetadata | ConvertTo-Json -Depth 4) + "`n", [Text.UTF8Encoding]::new($false))
  $metadataMismatchRejected = $false
  try {
    & $installer -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 30
  } catch {
    if ($_.Exception.Message -notmatch "discovery and root install metadata disagree") { throw }
    $metadataMismatchRejected = $true
  } finally {
    [IO.File]::WriteAllText($discoveryFile, $rootMetadataText, [Text.UTF8Encoding]::new($false))
  }
  Assert-True $metadataMismatchRejected "Installer accepted conflicting discovery and root metadata"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Wait-DalaVersion $initialPort $oldVersion

  $port = Get-FreePort
  $updatedConfig = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
  $updatedConfig.port = $port
  [IO.File]::WriteAllText($configFile, ($updatedConfig | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
  Set-SmokeTaskRunner $taskName $oldLauncher $runner $logFile $oldBatch $installRoot $port $oldVersion
  $env:DALA_PORT = [string]$port
  Assert-InstallContract $installRoot $dataDir $configFile $discoveryFile $taskName $port
  $rootMetadataText = Get-Content -LiteralPath $rootMetadataFile -Raw

  $previousConfigTaskName = $taskName
  $taskName = $taskName + "-config-migrated"
  $port = Get-FreePort
  $updatedConfig = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
  $updatedConfig.port = $port
  $updatedConfig.serviceName = $taskName
  $jsonc = "// Config-only lifecycle migration`r`n/* comments and trailing commas are supported */`r`n" +
    (($updatedConfig | ConvertTo-Json -Depth 8) -replace '\r?\n\}$', ",`r`n}") + "`r`n"
  [IO.File]::WriteAllText($configFile, $jsonc, [Text.UTF8Encoding]::new($false))

  # Leave the old ambient values in place: config.jsonc is the runtime
  # authority, so the installer must migrate from the file rather than env.
  & $installer -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
    -ExpectedVersion $oldVersion -HealthTimeoutSeconds 90
  Assert-True (-not (Get-ScheduledTask -TaskName $previousConfigTaskName -TaskPath "\" -ErrorAction SilentlyContinue)) "Config-only migration left the previous Scheduled Task"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Wait-DalaVersion $port $oldVersion
  $preservedJsonc = Get-Content -LiteralPath $configFile -Raw
  Assert-True ($preservedJsonc.Contains("Config-only lifecycle migration")) "Installer rewrote the user's JSONC configuration"
  [IO.File]::WriteAllText($configFile, ($updatedConfig | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))
  Assert-InstallContract $installRoot $dataDir $configFile $discoveryFile $taskName $port
  $rootMetadataText = Get-Content -LiteralPath $rootMetadataFile -Raw
  $env:DALA_SERVICE = $taskName
  $env:DALA_PORT = [string]$port

  $env:DALA_CONFIG = Join-Path $smokeRoot "ambient foreign config.jsonc"
  $installConflictRejected = $false
  try {
    & $installer -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 30
  } catch {
    if ($_.Exception.Message -notmatch "DALA_CONFIG conflicts") { throw }
    $installConflictRejected = $true
  } finally {
    $env:DALA_CONFIG = $configFile
  }
  Assert-True $installConflictRejected "Installer accepted ambient config conflicting with install.json"

  $env:DALA_SERVICE = $taskName + "-ambient-foreign"
  $uninstallConflictRejected = $false
  try { & $uninstall } catch {
    if ($_.Exception.Message -notmatch "DALA_SERVICE conflicts") { throw }
    $uninstallConflictRejected = $true
  } finally {
    $env:DALA_SERVICE = $taskName
  }
  Assert-True $uninstallConflictRejected "Uninstaller accepted ambient service name conflicting with install.json"
  Assert-True (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) "Conflict guard touched the installed task"
  Wait-DalaVersion $port $oldVersion

  $beam = Get-SmokeBeam $installRoot
  Assert-True $beam "Scheduled Task did not own a BEAM process"
  Assert-NoVisibleConsole ([uint32]$beam.ProcessId) $openConsolePidsBefore

  $wrapper = @"
`$env:APPDATA = '$scheduledAppData'
`$env:DALA_DISCOVERY_FILE = '$scheduledDiscoveryFile'
`$env:RELEASE_NAME = 'ambient-release'
`$env:RELEASE_VSN = '0.0.0-ambient'
`$env:RELEASE_MODE = 'ambient-mode'
`$env:RELEASE_NODE = '$releaseNode'
`$env:RELEASE_COOKIE = '$releaseCookie'
`$env:RELEASE_TMP = 'ambient-release-tmp'
`$env:RELEASE_VM_ARGS = 'ambient-vm.args'
`$env:RELEASE_REMOTE_VM_ARGS = 'ambient-remote.vm.args'
`$env:RELEASE_DISTRIBUTION = 'ambient-distribution'
`$env:RELEASE_BOOT_SCRIPT = 'ambient-boot'
`$env:RELEASE_BOOT_SCRIPT_CLEAN = 'ambient-clean-boot'
`$env:RELEASE_SYS_CONFIG = 'ambient-sys.config'
`$env:RELEASE_ROOT = 'ambient-release-root'
`$env:RELEASE_COMMAND = 'ambient-command'
`$env:RELEASE_PROG = 'ambient-prog'
`$env:RELEASE_MUTABLE_DIR = 'ambient-mutable'
`$env:RELEASE_READ_ONLY = 'ambient-read-only'
`$env:ERL_FLAGS = 'ambient-erl-flags'
`$env:ERL_AFLAGS = 'ambient-erl-aflags'
`$env:ERL_ZFLAGS = 'ambient-erl-zflags'
`$env:ERL_LIBS = 'ambient-erl-libs'
`$env:ERL_INETRC = 'ambient-erl-inetrc'
`$env:ERL_EPMD_PORT = 'ambient-erl-epmd-port'
`$env:ERL_EPMD_ADDRESS = '127.0.0.1'
`$env:ERL_EPMD_RELAXED_COMMAND_CHECK = '1'
`$env:ELIXIR_ERL_OPTIONS = 'ambient-elixir-options'
`$env:DALA_CONFIG = '$ambientRunnerConfig'
`$env:DALA_UPDATE_REPO = 'ambient/foreign-repo'
`$env:DALA_SCHEME = 'https'
`$env:PHX_SCHEME = 'https'
`$env:DALA_POOL_SIZE = '99'
`$env:POOL_SIZE = '99'
`$env:SECRET_KEY_BASE = '$secretBait'
`$env:TOKEN_SIGNING_SECRET = '$tokenBait'
`$env:DALA_SECRET_KEY_BASE = '$secretBait'
`$env:DALA_TOKEN_SIGNING_SECRET = '$tokenBait'
& (Join-Path `$PSScriptRoot 'run-dala.ps1')
exit `$LASTEXITCODE
"@
  [IO.File]::WriteAllText($smokeRunner, $wrapper, [Text.UTF8Encoding]::new($false))
  Set-SmokeTaskRunner $taskName $oldLauncher $smokeRunner $logFile $oldBatch $installRoot $port $oldVersion
  $rootMetadataAfterTask = Get-Content -LiteralPath $rootMetadataFile -Raw | ConvertFrom-Json
  Assert-True (Test-SamePath ([string]$rootMetadataAfterTask.discoveryFile) $discoveryFile) `
    "Root metadata did not persist the canonical discovery path"
  Assert-True ((Get-Content -LiteralPath $scheduledDiscoveryFile -Raw) -ceq $scheduledDiscoveryOriginal) `
    "Runner touched the decoy discovery metadata under the scheduled-task APPDATA"

  $spawnSource = @'
alias Dala.Terminal.{Holder, Shell}

id = __SESSION_ID__
marker = __MARKER__
result_path = __RESULT_PATH__
data_dir = __DATA_DIR__
secret_bait = __SECRET_BAIT__
token_bait = __TOKEN_BAIT__
config_file = __CONFIG_FILE__

secret_names = ~w(SECRET_KEY_BASE TOKEN_SIGNING_SECRET DALA_SECRET_KEY_BASE DALA_TOKEN_SIGNING_SECRET)
true = Enum.all?(secret_names, &(System.get_env(&1) == nil))
true = System.get_env("DALA_CONFIG") == config_file
clean_names = ~w(
  DALA_DISCOVERY_FILE DALA_UPDATE_REPO DALA_SCHEME PHX_SCHEME DALA_POOL_SIZE POOL_SIZE
  RELEASE_NAME RELEASE_VSN RELEASE_MODE RELEASE_NODE RELEASE_COOKIE RELEASE_TMP
  RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_DISTRIBUTION RELEASE_BOOT_SCRIPT
  RELEASE_BOOT_SCRIPT_CLEAN RELEASE_SYS_CONFIG RELEASE_ROOT RELEASE_COMMAND RELEASE_PROG
  RELEASE_MUTABLE_DIR RELEASE_READ_ONLY ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS ERL_LIBS
  ERL_INETRC ERL_EPMD_PORT ERL_EPMD_ADDRESS ERL_EPMD_RELAXED_COMMAND_CHECK
  ELIXIR_ERL_OPTIONS
)
true = Enum.all?(clean_names, &(System.get_env(&1) == nil))
secrets = data_dir |> Path.join("secrets.json") |> File.read!() |> Jason.decode!()
environment_values = System.get_env() |> Map.values()
true = Enum.all?([secrets["secretKeyBase"], secrets["tokenSigningSecret"]], &(&1 not in environment_values))

receive_frame = fn receive_frame, socket, expected_type ->
  receive do
    {:tcp, ^socket, <<^expected_type, payload::binary>>} -> payload
    {:tcp, ^socket, _other} -> receive_frame.(receive_frame, socket, expected_type)
  after
    5_000 -> raise "holder frame timeout"
  end
end

shell = Shell.default_shell()
shell_options = Shell.spawn_options(shell)
opts = [
  shell: shell,
  args: shell_options[:args],
  cwd: data_dir,
  env: [{"TERM", "xterm-256color"}, {"COLORTERM", "truecolor"}] ++ shell_options[:env],
  env_remove: ["TERM_PROGRAM", "WT_SESSION", "WT_PROFILE_ID"],
  rows: 24,
  cols: 100,
  history_lines: 1_000
]

{:ok, socket, false} = Holder.attach_or_spawn(id, opts)
hello = receive_frame.(receive_frame, socket, Holder.type_hello()) |> Jason.decode!()
command = "Write-Output '#{marker}'; Write-Output ('DALA_ENV|' + [string]$env:SECRET_KEY_BASE + '|' + [string]$env:TOKEN_SIGNING_SECRET + '|' + [string]$env:DALA_SECRET_KEY_BASE + '|' + [string]$env:DALA_TOKEN_SIGNING_SECRET)\r"
:ok = Holder.send_input(socket, command)

read_output = fn read_output, acc ->
  payload = receive_frame.(receive_frame, socket, Holder.type_output())
  output = acc <> payload
  if String.contains?(output, marker) and String.contains?(output, "DALA_ENV||||"),
    do: output,
    else: read_output.(read_output, output)
end

output = read_output.(read_output, "")
false = String.contains?(output, secret_bait)
false = String.contains?(output, token_bait)
:gen_tcp.close(socket)
File.write!(result_path, Jason.encode!(%{spawned: true, env_clean: true, shell_pid: hello["pid"]}))
'@
  $spawnSource = $spawnSource.Replace("__SESSION_ID__", ($sessionId | ConvertTo-Json -Compress))
  $spawnSource = $spawnSource.Replace("__MARKER__", ($marker | ConvertTo-Json -Compress))
  $spawnSource = $spawnSource.Replace("__RESULT_PATH__", ($resultFile | ConvertTo-Json -Compress))
  $spawnSource = $spawnSource.Replace("__DATA_DIR__", ($dataDir | ConvertTo-Json -Compress))
  $spawnSource = $spawnSource.Replace("__SECRET_BAIT__", ($secretBait | ConvertTo-Json -Compress))
  $spawnSource = $spawnSource.Replace("__TOKEN_BAIT__", ($tokenBait | ConvertTo-Json -Compress))
  $spawnSource = $spawnSource.Replace("__CONFIG_FILE__", ($configFile | ConvertTo-Json -Compress))
  Invoke-ReleaseRpc $oldBatch $spawnSource

  $spawnResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
  Assert-True ($spawnResult.spawned -and $spawnResult.env_clean) "Old release did not spawn a clean holder"
  $shellPid = [uint32]$spawnResult.shell_pid
  $holder = Get-CimInstance Win32_Process -Filter "Name='dala_holder.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$sessionId*" } |
    Select-Object -First 1
  Assert-True $holder "Detached holder process was not found"
  $holderPid = [uint32]$holder.ProcessId
  Assert-True (Get-Process -Id $shellPid -ErrorAction SilentlyContinue) "Holder shell process was not found"

  $normalOldAction = New-ScheduledTaskAction -Execute $oldLauncher -Argument "`"$runner`" `"$logFile`""
  Set-ScheduledTask -TaskName $taskName -Action $normalOldAction | Out-Null
  Assert-TaskAction $taskName $oldLauncher $runner $logFile

  $badExpected = "0.0.999-smoke-mismatch"
  $installerFailed = $false
  $installerRollbackAttemptId = New-SmokeAttemptId
  try {
    & $installer -Version $newTag -ArchivePath $archive -ChecksumPath $checksum `
      -ExpectedVersion $badExpected -HealthTimeoutSeconds 30 -AttemptId $installerRollbackAttemptId
  } catch {
    if ($_.Exception.Message -notmatch "Dala update failed") { throw }
    $installerFailed = $true
  }
  Assert-True $installerFailed "Installer update with the wrong expected version unexpectedly succeeded"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Installer rollback did not restore current.txt"
  Wait-DalaVersion $port $oldVersion
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  $installerRollbackResultFile = Join-Path $installRoot "logs\update-results\$installerRollbackAttemptId.json"
  $installerRollback = Get-Content -LiteralPath $installerRollbackResultFile -Raw | ConvertFrom-Json
  Assert-UpdateResultAttempt $installerRollback $installerRollbackAttemptId
  Assert-True (-not $installerRollback.success -and $installerRollback.rolled_back) "Installer rollback result is not authoritative"
  Assert-True (Get-Process -Id $holderPid -ErrorAction SilentlyContinue) "Holder died during installer rollback"
  Assert-True (Get-Process -Id $shellPid -ErrorAction SilentlyContinue) "Shell died during installer rollback"

  $newDir = Join-Path $installRoot "versions\$newTag"
  $newHelper = Get-UpdateHelper $newDir
  Assert-True $newHelper "Staged new release is missing update-dala.ps1"
  $newPublishHelper = Get-PublishHelper $newDir $newVersion
  Assert-True $newPublishHelper "Staged new release is missing publish-dala.ps1"

  do {
    $canonicalAttemptId = New-SmokeAttemptId
  } while ($canonicalAttemptId -cnotmatch '[a-f]')
  $nonCanonicalAttemptId = $canonicalAttemptId.ToUpperInvariant()
  $invalidAttemptOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $newHelper `
    -InstallRoot $installRoot -TaskName $taskName -TargetTag $newTag -PreviousTag $oldTag `
    -ExpectedVersion $newVersion -PreviousVersion $oldVersion -AttemptId $nonCanonicalAttemptId `
    -ResultFile $invalidAttemptResultFile 2>&1 | Out-String
  $invalidAttemptStatus = $LASTEXITCODE
  Assert-True ($invalidAttemptStatus -ne 0) "Helper accepted a non-canonical AttemptId"
  Assert-True ($invalidAttemptOutput -match "canonical UUID") "Helper returned the wrong non-canonical AttemptId error"
  Assert-True (-not (Test-Path -LiteralPath $invalidAttemptResultFile)) "Rejected AttemptId created an uncorrelatable result"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Rejected AttemptId changed current.txt"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile

  $validRootMetadata = Get-Content -LiteralPath $rootMetadataFile -Raw
  $invalidRootMetadata = $validRootMetadata | ConvertFrom-Json
  $invalidRootMetadata.configFile = ""
  [IO.File]::WriteAllText($rootMetadataFile, ($invalidRootMetadata | ConvertTo-Json -Depth 4) + "`n", [Text.UTF8Encoding]::new($false))
  $invalidMetadataAttemptId = New-SmokeAttemptId
  try {
    Remove-Item -LiteralPath $invalidMetadataResultFile -Force -ErrorAction SilentlyContinue
    $invalidMetadataResult = Invoke-DetachedUpdateHelper $newHelper $installRoot $taskName $newTag $oldTag `
      $newVersion $oldVersion $invalidMetadataResultFile -AttemptId $invalidMetadataAttemptId
  } finally {
    [IO.File]::WriteAllText($rootMetadataFile, $validRootMetadata, [Text.UTF8Encoding]::new($false))
  }
  Assert-True (-not $invalidMetadataResult.success -and -not $invalidMetadataResult.rolled_back) "Helper accepted empty install metadata"
  Assert-True ([string]$invalidMetadataResult.message -match "configFile.*empty") "Helper returned the wrong metadata validation error"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Invalid metadata changed current.txt"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile

  Remove-Item -LiteralPath $runner -Force
  $missingRunnerAttemptId = New-SmokeAttemptId
  $missingRunnerResult = Invoke-DetachedUpdateHelper $newHelper $installRoot $taskName $newTag $oldTag `
    $badExpected $oldVersion (Join-Path $smokeRoot "missing-runner-result.json") `
    -AttemptId $missingRunnerAttemptId
  Assert-True (-not $missingRunnerResult.success -and $missingRunnerResult.rolled_back) "Missing root runner did not roll back"
  Assert-True (Test-Path -LiteralPath $runner -PathType Leaf) "Rollback did not restore a missing root runner"
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $oldDir "run-dala.ps1")).Hash) "Rollback restored the target runner instead of the previous runner"
  Wait-DalaVersion $port $oldVersion
  Assert-TaskAction $taskName $oldLauncher $runner $logFile

  $publishStagingRoot = Join-Path $smokeRoot "publish staging area"
  $publishDestinationRoot = Join-Path $smokeRoot "publish destination area"
  $publishStaging = Join-Path $publishStagingRoot "first candidate"
  $publishDestination = Join-Path $publishDestinationRoot "release"
  $publishDestinationSentinel = Join-Path $publishDestination "incomplete-sentinel.txt"
  Write-PublishFixture $publishStaging $newVersion "first-winner" $newPublishHelper
  [IO.Directory]::CreateDirectory($publishDestination) | Out-Null
  [IO.File]::WriteAllText($publishDestinationSentinel, "must remain while locked")

  # A rollback directory left by an interrupted publisher is ambiguous even
  # when the previous destination still exists. Refuse to guess which tree is
  # authoritative and leave both paths available for manual recovery.
  $orphanPublishStaging = Join-Path $publishStagingRoot "orphan candidate"
  $orphanPublishDestination = Join-Path $publishDestinationRoot "orphan release"
  $orphanPublishBackup = Join-Path $publishDestinationRoot `
    ".ORPHAN RELEASE.rollback-legacy-token"
  Write-PublishFixture $orphanPublishStaging $newVersion "orphan-candidate" $newPublishHelper
  Write-PublishFixture $orphanPublishDestination $newVersion "orphan-destination" $newPublishHelper
  Write-PublishFixture $orphanPublishBackup $newVersion "orphan-backup" $newPublishHelper
  $orphanPublishOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $newPublishHelper -StagingDir $orphanPublishStaging -DestinationDir $orphanPublishDestination `
    -ExpectedVersion $newVersion 2>&1 | Out-String
  $orphanPublishStatus = $LASTEXITCODE
  Assert-True ($orphanPublishStatus -ne 0) "Publisher ignored an orphan rollback beside a complete destination"
  Assert-True ($orphanPublishOutput -match "manual recovery") "Publisher returned the wrong orphan rollback error"
  Assert-True (Test-Path -LiteralPath $orphanPublishBackup -PathType Container) "Publisher removed an orphan rollback"
  Assert-True (((Get-Content -LiteralPath (Join-Path $orphanPublishDestination "publish-marker.txt") -Raw) -ceq "orphan-destination")) `
    "Publisher changed the destination while rejecting an orphan rollback"
  Remove-Item -LiteralPath $orphanPublishStaging, $orphanPublishDestination, $orphanPublishBackup -Recurse -Force

  $failedPublishStaging = Join-Path $publishStagingRoot "copy failure candidate"
  $failedPublishDestination = Join-Path $publishDestinationRoot "failed release"
  $failedPublishSentinel = Join-Path $failedPublishDestination "incomplete-sentinel.txt"
  $lockedCopyFile = Join-Path $failedPublishStaging "locked-copy.bin"
  Write-PublishFixture $failedPublishStaging $newVersion "must-not-publish" $newPublishHelper
  [IO.File]::WriteAllText($lockedCopyFile, "locked")
  [IO.Directory]::CreateDirectory($failedPublishDestination) | Out-Null
  [IO.File]::WriteAllText($failedPublishSentinel, "must survive copy failure")
  $lockedCopyStream = [IO.File]::Open($lockedCopyFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  try {
    $failedPublishOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File $newPublishHelper -StagingDir $failedPublishStaging -DestinationDir $failedPublishDestination `
      -ExpectedVersion $newVersion 2>&1 | Out-String
    $failedPublishStatus = $LASTEXITCODE
  } finally {
    $lockedCopyStream.Dispose()
  }
  Assert-True ($failedPublishStatus -ne 0) "Publisher accepted a partial destination-parent copy"
  Assert-True ($failedPublishOutput -match [regex]::Escape($lockedCopyFile)) "Copy failure did not reach the locked staging file"
  Assert-True (Test-Path -LiteralPath $failedPublishSentinel -PathType Leaf) "Copy failure replaced the incomplete destination"
  Assert-True (Test-Path -LiteralPath (Join-Path $failedPublishStaging "publish-marker.txt") -PathType Leaf) "Copy failure changed staging"
  $failedPublishTemps = @(
    Get-ChildItem -LiteralPath $publishDestinationRoot -Directory -Force |
      Where-Object { $_.Name -like ".failed release.publish-*" }
  )
  Assert-True ($failedPublishTemps.Count -eq 0) "Copy failure left a partial publish directory"

  $blockedPublishStaging = Join-Path $publishStagingRoot "blocked destination candidate"
  $blockedPublishDestination = Join-Path $publishDestinationRoot "blocked release"
  Write-PublishFixture $blockedPublishStaging $newVersion "blocked-destination" $newPublishHelper
  [IO.File]::WriteAllText($blockedPublishDestination, "must survive commit failure")
  $blockedDestinationStream = [IO.File]::Open(
    $blockedPublishDestination,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::None
  )
  try {
    $blockedPublishOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File $newPublishHelper -StagingDir $blockedPublishStaging `
      -DestinationDir $blockedPublishDestination -ExpectedVersion $newVersion 2>&1 | Out-String
    $blockedPublishStatus = $LASTEXITCODE
  } finally {
    $blockedDestinationStream.Dispose()
  }
  Assert-True ($blockedPublishStatus -ne 0) "Publisher replaced an exclusively locked destination"
  Assert-True ($blockedPublishOutput -match [regex]::Escape($blockedPublishDestination)) "Commit failure did not reach the locked destination"
  Assert-True ((Get-Content -LiteralPath $blockedPublishDestination -Raw) -ceq "must survive commit failure") "Commit failure changed the previous destination"
  $blockedPublishArtifacts = @(
    Get-ChildItem -LiteralPath $publishDestinationRoot -Force |
      Where-Object { $_.Name -like ".blocked release.publish-*" -or $_.Name -like ".blocked release.rollback-*" }
  )
  Assert-True ($blockedPublishArtifacts.Count -eq 0) "Commit failure left a publish or rollback artifact"

  $runnerHashBeforeLock = (Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash
  $lockHandle = Enter-SmokeLifecycleMutex
  try {
    $lockedPublishOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File $newPublishHelper -StagingDir $publishStaging -DestinationDir $publishDestination `
      -ExpectedVersion $newVersion 2>&1 | Out-String
    $lockedPublishStatus = $LASTEXITCODE
    Assert-True ($lockedPublishStatus -ne 0) "Publisher ignored the lifecycle mutex"
    Assert-True ($lockedPublishOutput -match "already in progress") "Publisher returned the wrong lifecycle-lock error"
    Assert-True (Test-Path -LiteralPath (Join-Path $publishStaging "publish-marker.txt") -PathType Leaf) "Locked publisher changed staging"
    Assert-True (Test-Path -LiteralPath $publishDestinationSentinel -PathType Leaf) "Locked publisher changed the incomplete destination"

    $wmiLockedAttemptId = New-SmokeAttemptId
    Remove-Item -LiteralPath $wmiLockedResultFile -Force -ErrorAction SilentlyContinue
    $wmiLockPid = Start-DetachedUpdateHelper $newHelper $installRoot $taskName $newTag $newTag `
      $newVersion $newVersion $wmiLockedResultFile 0 -AttemptId $wmiLockedAttemptId
    Wait-Process -Id $wmiLockPid -Timeout 30 -ErrorAction SilentlyContinue
    Assert-True (-not (Get-Process -Id $wmiLockPid -ErrorAction SilentlyContinue)) "Zero-timeout WMI helper did not exit under lifecycle lock contention"
    $wmiLockPid = $null
    $wmiLockedResult = Wait-UpdateResult $wmiLockedResultFile $wmiLockedAttemptId
    Assert-True (-not $wmiLockedResult.success -and -not $wmiLockedResult.rolled_back) "Cross-session WMI lock loser returned the wrong result"
    Assert-True ([string]$wmiLockedResult.message -match "already in progress") "Cross-session WMI helper acquired a held lifecycle mutex"

    $staleAttemptId = New-SmokeAttemptId
    Remove-Item -LiteralPath $staleResultFile -Force -ErrorAction SilentlyContinue
    $staleLockPid = Start-DetachedUpdateHelper $newHelper $installRoot $taskName $newTag $newTag `
      $newVersion $newVersion $staleResultFile 120000 -AttemptId $staleAttemptId
    Start-Sleep -Milliseconds 500
    $staleWmiProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$staleLockPid" -ErrorAction SilentlyContinue
    Assert-True $staleWmiProcess "WMI helper exited instead of waiting for the cross-session lifecycle mutex"
    $smokeSessionId = (Get-Process -Id $PID -ErrorAction Stop).SessionId
    Assert-True ([uint32]$staleWmiProcess.SessionId -ne [uint32]$smokeSessionId) "Win32_Process.Create did not provide a distinct session for the global-mutex smoke"
    Assert-True (-not (Test-Path -LiteralPath $staleResultFile)) "WMI helper crossed the held lifecycle mutex"
    Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Waiting WMI helper changed current.txt"
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash -ceq $runnerHashBeforeLock) "Waiting WMI helper changed run-dala.ps1"
    Assert-TaskAction $taskName $oldLauncher $runner $logFile

    $lockedAttemptId = New-SmokeAttemptId
    Remove-Item -LiteralPath $lockedResultFile -Force -ErrorAction SilentlyContinue
    $lockedOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $newHelper `
      -InstallRoot $installRoot -TaskName $taskName -TargetTag $newTag -PreviousTag $oldTag `
      -ExpectedVersion $newVersion -PreviousVersion $oldVersion -AttemptId $lockedAttemptId `
      -ResultFile $lockedResultFile `
      -LockTimeoutMilliseconds 0 2>&1 | Out-String
    $lockedStatus = $LASTEXITCODE

    $validDiscoveryMetadata = Get-Content -LiteralPath $discoveryFile -Raw
    [IO.File]::WriteAllText($discoveryFile, "{invalid metadata")
    try {
      $lockedExistingInstallOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer `
        -Version $newTag -ArchivePath $archive -ChecksumPath $checksum `
        -ExpectedVersion $newVersion -HealthTimeoutSeconds 30 2>&1 | Out-String
      $lockedExistingInstallStatus = $LASTEXITCODE
      $lockedUninstallOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $uninstall 2>&1 | Out-String
      $lockedUninstallStatus = $LASTEXITCODE
    } finally {
      [IO.File]::WriteAllText($discoveryFile, $validDiscoveryMetadata, [Text.UTF8Encoding]::new($false))
    }
  } finally {
    Exit-SmokeLifecycleMutex $lockHandle
  }
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $newPublishHelper -StagingDir $publishStaging -DestinationDir $publishDestination `
    -ExpectedVersion $newVersion
  Assert-True ($LASTEXITCODE -eq 0) "Publisher failed after the lifecycle mutex was released"
  Assert-True (Test-Path -LiteralPath $publishStaging -PathType Container) "Publisher unexpectedly removed source staging"
  Assert-True (-not (Test-Path -LiteralPath $publishDestinationSentinel)) "Publisher preserved an incomplete destination"
  Assert-True (((Get-Content -LiteralPath (Join-Path $publishDestination "publish-marker.txt") -Raw) -ceq "first-winner")) "Publisher did not install the staged release"
  $publishTemps = @(
    Get-ChildItem -LiteralPath $publishDestinationRoot -Directory -Force |
      Where-Object { $_.Name -like ".release.publish-*" }
  )
  Assert-True ($publishTemps.Count -eq 0) "Successful publisher left a temporary publish directory"

  $fullTreeRelative = "lib\dala-$newVersion\ebin\Elixir.Dala.FullTreeRegression.beam"
  $fullTreeSource = Join-Path $publishStaging $fullTreeRelative
  $fullTreeDestination = Join-Path $publishDestination $fullTreeRelative
  [IO.File]::WriteAllText($fullTreeSource, "full release tree")
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $newPublishHelper -StagingDir $publishStaging -DestinationDir $publishDestination `
    -ExpectedVersion $newVersion
  Assert-True ($LASTEXITCODE -eq 0) "Publisher ignored a non-key release file"
  Assert-True (Test-Path -LiteralPath $fullTreeDestination -PathType Leaf) "Publisher omitted a non-key release file"

  Remove-Item -LiteralPath $fullTreeDestination -Force
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $newPublishHelper -StagingDir $publishStaging -DestinationDir $publishDestination `
    -ExpectedVersion $newVersion
  Assert-True ($LASTEXITCODE -eq 0) "Publisher accepted a destination missing a non-key release file"
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $fullTreeDestination).Hash -ceq
    (Get-FileHash -Algorithm SHA256 -LiteralPath $fullTreeSource).Hash) "Publisher did not restore the missing non-key release file"

  $losingPublishStaging = Join-Path $publishStagingRoot "second candidate"
  Write-PublishFixture $losingPublishStaging $newVersion "first-winner" $newPublishHelper
  [IO.File]::WriteAllText((Join-Path $losingPublishStaging $fullTreeRelative), "full release tree")
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $newPublishHelper -StagingDir $losingPublishStaging -DestinationDir $publishDestination `
    -ExpectedVersion $newVersion
  Assert-True ($LASTEXITCODE -eq 0) "Publisher did not accept an already complete destination"
  Assert-True (Test-Path -LiteralPath $losingPublishStaging -PathType Container) "Publisher removed the losing staging directory"
  Assert-True (((Get-Content -LiteralPath (Join-Path $publishDestination "publish-marker.txt") -Raw) -ceq "first-winner")) "Publisher overwrote the complete winning release"

  $mismatchedPublishStaging = Join-Path $publishStagingRoot "version replacement candidate"
  $mismatchedPublishDestination = Join-Path $publishDestinationRoot "mismatched release"
  Write-PublishFixture $mismatchedPublishStaging $newVersion "correct-version" $newPublishHelper
  Write-PublishFixture $mismatchedPublishDestination $oldVersion "wrong-version" $newPublishHelper
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $newPublishHelper -StagingDir $mismatchedPublishStaging `
    -DestinationDir $mismatchedPublishDestination -ExpectedVersion $newVersion
  Assert-True ($LASTEXITCODE -eq 0) "Publisher did not replace a complete release with the wrong version"
  Assert-True (Test-Path -LiteralPath $mismatchedPublishStaging -PathType Container) "Version-replacement publisher removed source staging"
  Assert-True (((Get-Content -LiteralPath (Join-Path $mismatchedPublishDestination "publish-marker.txt") -Raw) -ceq "correct-version")) "Publisher preserved a release with the wrong version"
  Assert-True ((Get-DalaAppVersion $mismatchedPublishDestination) -ceq $newVersion) "Version-replacement publisher installed the wrong dala.app"
  Assert-True (((Get-Content -LiteralPath (Join-Path $mismatchedPublishDestination "releases\start_erl.data") -Raw).Trim() -split '\s+')[1] -ceq $newVersion) "Version-replacement publisher installed the wrong start_erl.data"
  Assert-True (Get-PublishHelper $mismatchedPublishDestination $newVersion) "Version-replacement publisher installed the helper outside the expected app root"

  $staleResult = Wait-UpdateResult $staleResultFile $staleAttemptId
  Wait-Process -Id $staleLockPid -Timeout 30 -ErrorAction SilentlyContinue
  Assert-True (-not (Get-Process -Id $staleLockPid -ErrorAction SilentlyContinue)) "WMI helper did not exit after acquiring the released lifecycle mutex"
  $staleLockPid = $null
  Assert-True (-not $staleResult.success -and -not $staleResult.rolled_back) "Stale WMI helper unexpectedly changed the installation"
  Assert-True ([string]$staleResult.message -match "current release changed") "Stale WMI helper did not report the current.txt CAS failure"
  Assert-True ($lockedStatus -ne 0) "Concurrent helper did not fail closed on the update lock"
  Assert-True ($lockedOutput -match "already in progress") "Concurrent helper returned the wrong lock error"
  $lockedResult = Wait-UpdateResult $lockedResultFile $lockedAttemptId
  Assert-True (-not $lockedResult.success -and -not $lockedResult.rolled_back) "Lock loser returned the wrong correlated result"
  Assert-True ([string]$lockedResult.message -match "already in progress") "Lock loser result returned the wrong error"
  Assert-True ($lockedExistingInstallStatus -ne 0) "Existing installer ignored the lifecycle mutex"
  Assert-True ($lockedExistingInstallOutput -match "already in progress") "Existing installer read metadata before acquiring the lifecycle mutex"
  Assert-True ($lockedUninstallStatus -ne 0) "Uninstaller ignored the lifecycle lock"
  Assert-True ($lockedUninstallOutput -match "already in progress") "Uninstaller read metadata before acquiring the lifecycle mutex"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Lock contention changed current.txt"
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash -ceq $runnerHashBeforeLock) "Lock contention changed run-dala.ps1"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Wait-DalaVersion $port $oldVersion

  Stop-SmokeRelease $taskName $oldBatch $installRoot $port
  $targetRunnerPath = Join-Path $newDir "run-dala.ps1"
  $targetRunnerBody = Get-Content -LiteralPath $targetRunnerPath -Raw
  Write-DummyReleaseRunner $targetRunnerPath $newTag
  $updateDecoyProcess = Start-VersionDecoy $port $newVersion
  $healthDecoyAttemptId = New-SmokeAttemptId
  Remove-Item -LiteralPath $healthDecoyResultFile -Force -ErrorAction SilentlyContinue
  $healthDecoyWaitError = $null
  try {
    $healthDecoyOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $newHelper `
      -InstallRoot $installRoot -TaskName $taskName -TargetTag $newTag -PreviousTag $oldTag `
      -ExpectedVersion $newVersion -AttemptId $healthDecoyAttemptId `
      -ResultFile $healthDecoyResultFile -HealthTimeoutSeconds 5 2>&1 | Out-String
    $healthDecoyStatus = $LASTEXITCODE
  } finally {
    try {
      Wait-VersionDecoyExited $updateDecoyProcess "Update version decoy"
    } catch {
      # Keep the helper's own rejection output/status authoritative. A helper
      # failure may happen before it probes the one-shot decoy.
      $healthDecoyWaitError = $_
    } finally {
      Stop-VersionDecoy $updateDecoyProcess
      $updateDecoyProcess = $null
      [IO.File]::WriteAllText($targetRunnerPath, $targetRunnerBody, [Text.UTF8Encoding]::new($false))
    }
  }
  if ($healthDecoyWaitError -and $healthDecoyStatus -eq 0) {
    throw $healthDecoyWaitError
  }

  $healthDecoyResult = Get-Content -LiteralPath $healthDecoyResultFile -Raw | ConvertFrom-Json
  Assert-UpdateResultAttempt $healthDecoyResult $healthDecoyAttemptId
  Assert-True ($healthDecoyStatus -ne 0) "Update helper accepted a same-version response from a foreign port owner"
  Assert-True ($healthDecoyOutput -match "did not become healthy") "Update decoy failure returned the wrong error"
  Assert-True (-not $healthDecoyResult.success -and $healthDecoyResult.rolled_back) "Update decoy did not roll back"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Update decoy rollback did not restore current.txt"
  $targetStartData = @((Get-Content -LiteralPath (Join-Path $newDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
  Assert-True ($targetStartData.Count -eq 2) "Update decoy target has malformed start_erl.data"
  $targetEpmdPath = Join-Path $newDir "erts-$($targetStartData[0])\bin\epmd.exe"
  Assert-NoOwnedEpmdProcess $targetEpmdPath "Update health rollback"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine.IndexOf($newDir, [StringComparison]::OrdinalIgnoreCase) -ge 0
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  Start-ScheduledTask -TaskName $taskName
  Wait-DalaVersion $port $oldVersion

  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "CAS failure changed current.txt"
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash -ceq $runnerHashBeforeLock) "CAS failure changed run-dala.ps1"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile

  $foreignTag = "v9.9.9"
  $rollbackCasAttemptId = New-SmokeAttemptId
  Remove-Item -LiteralPath $rollbackCasResultFile -Force -ErrorAction SilentlyContinue
  $rollbackCasPid = Start-DetachedUpdateHelper $newHelper $installRoot $taskName $newTag $oldTag `
    $badExpected $oldVersion $rollbackCasResultFile -AttemptId $rollbackCasAttemptId
  $targetObserved = $false
  for ($attempt = 0; $attempt -lt 1800; $attempt++) {
    $observedTag = (Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()
    if ($observedTag -ceq $newTag) {
      $targetObserved = $true
      [IO.File]::WriteAllText((Join-Path $installRoot "current.txt"), "$foreignTag`n", [Text.UTF8Encoding]::new($false))
      break
    }
    Start-Sleep -Milliseconds 25
  }
  Assert-True $targetObserved "Could not interleave an external current.txt change before rollback"
  $rollbackCas = Wait-UpdateResult $rollbackCasResultFile $rollbackCasAttemptId
  Wait-Process -Id $rollbackCasPid -Timeout 30 -ErrorAction SilentlyContinue
  Assert-True (-not $rollbackCas.success -and -not $rollbackCas.rolled_back) "Rollback ignored the current.txt CAS"
  Assert-True ([string]$rollbackCas.message -match "refusing rollback") "Rollback CAS returned the wrong error"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $foreignTag) "Rollback overwrote an externally changed current.txt"
  $stagedLauncher = Get-TaskLauncher $newDir
  Assert-TaskAction $taskName $stagedLauncher $runner $logFile
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $runner).Hash -ceq (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $newDir "run-dala.ps1")).Hash) "Rollback CAS overwrote the target runner"
  $retainedRunnerBackups = @(
    Get-ChildItem -LiteralPath $installRoot -Filter ".run-dala.rollback-*.ps1" -File -Force
  )
  Assert-True ($retainedRunnerBackups.Count -eq 1) `
    "Incomplete rollback did not retain exactly one previous runner backup"
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $retainedRunnerBackups[0].FullName).Hash -ceq `
      (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $oldDir "run-dala.ps1")).Hash) `
    "Incomplete rollback retained the wrong runner bytes"

  [IO.File]::WriteAllText((Join-Path $installRoot "current.txt"), "$newTag`n", [Text.UTF8Encoding]::new($false))
  $restoreAttemptId = New-SmokeAttemptId
  Remove-Item -LiteralPath $restoreResultFile -Force -ErrorAction SilentlyContinue
  $restoreResult = Invoke-DetachedUpdateHelper (Get-UpdateHelper $oldDir) $installRoot $taskName $oldTag $newTag `
    $oldVersion $newVersion $restoreResultFile -AttemptId $restoreAttemptId
  Assert-True $restoreResult.success "Could not restore the old release after the rollback CAS test"
  Wait-DalaVersion $port $oldVersion
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Assert-True (Test-Path -LiteralPath $retainedRunnerBackups[0].FullName -PathType Leaf) `
    "Successful recovery removed the retained runner backup from the incomplete attempt"
  Remove-Item -LiteralPath $retainedRunnerBackups[0].FullName -Force

  $sidebarAttemptId = New-SmokeAttemptId
  Remove-Item -LiteralPath $sidebarResultFile -Force -ErrorAction SilentlyContinue
  $sidebarRollback = Invoke-DetachedUpdateHelper $newHelper $installRoot $taskName $newTag $oldTag `
    $badExpected $oldVersion $sidebarResultFile -AttemptId $sidebarAttemptId
  Assert-True (-not $sidebarRollback.success -and $sidebarRollback.rolled_back) "Sidebar-style helper did not report rollback"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Sidebar rollback did not restore current.txt"
  Wait-DalaVersion $port $oldVersion
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Assert-True (Get-Process -Id $holderPid -ErrorAction SilentlyContinue) "Holder died during sidebar rollback"
  Assert-True (Get-Process -Id $shellPid -ErrorAction SilentlyContinue) "Shell died during sidebar rollback"

  # Same-release-root bait: the executable is the packaged erl.exe, but it
  # has no release -boot argument. Ownership must not fall back to a path
  # substring or kill this process during update.
  $foreignUpdateErl = Start-ForeignErl $expandedNew (Join-Path $expandedNew "releases\$newVersion\same-root-bait")
  $foreignUpdateErlPid = [uint32]$foreignUpdateErl.Id
  Remove-Item -LiteralPath $newDir -Recurse -Force
  $lifecycleAppData = $env:APPDATA
  $lifecycleDiscoveryFile = $env:DALA_DISCOVERY_FILE
  $env:APPDATA = $scheduledAppData
  $env:DALA_DISCOVERY_FILE = $scheduledDiscoveryFile
  try {
    & $installer -Version $newTag -ArchivePath $archive -ChecksumPath $checksum `
      -ExpectedVersion $newVersion -HealthTimeoutSeconds 90
  } finally {
    $env:APPDATA = $lifecycleAppData
    $env:DALA_DISCOVERY_FILE = $lifecycleDiscoveryFile
  }
  Wait-DalaVersion $port $newVersion

  $newDir = Join-Path $installRoot "versions\$newTag"
  $newBatch = Join-Path $newDir "bin\dala.bat"
  $newLauncher = Get-TaskLauncher $newDir
  Assert-True $newLauncher "Installed new release is missing dala_task_launcher.exe"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $newTag) "Successful update did not switch current.txt"
  Assert-TaskAction $taskName $newLauncher $runner $logFile
  Assert-True (Get-Process -Id $holderPid -ErrorAction SilentlyContinue) "Holder PID changed during successful update"
  Assert-True (Get-Process -Id $shellPid -ErrorAction SilentlyContinue) "Shell PID changed during successful update"
  Assert-True (Get-Process -Id $foreignUpdateErlPid -ErrorAction SilentlyContinue) "Updater killed an unrelated sibling-path Erl process"
  Assert-InstallContract $installRoot $dataDir $configFile $discoveryFile $taskName $port
  Assert-True ((Get-Content -LiteralPath $scheduledDiscoveryFile -Raw) -ceq $scheduledDiscoveryOriginal) `
    "Release update modified the decoy discovery metadata under the scheduled-task APPDATA"
  Stop-Process -Id $foreignUpdateErlPid -Force -ErrorAction SilentlyContinue
  $foreignUpdateErlPid = $null

  Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
  Set-SmokeTaskRunner $taskName $newLauncher $smokeRunner $logFile $newBatch $installRoot $port $newVersion
  Assert-True ((Get-Content -LiteralPath $scheduledDiscoveryFile -Raw) -ceq $scheduledDiscoveryOriginal) `
    "Runner restart modified the decoy discovery metadata under the scheduled-task APPDATA"

  $reattachSource = @'
alias Dala.Terminal.Holder

id = __SESSION_ID__
marker = __MARKER__
result_path = __RESULT_PATH__
secret_names = ~w(SECRET_KEY_BASE TOKEN_SIGNING_SECRET DALA_SECRET_KEY_BASE DALA_TOKEN_SIGNING_SECRET)
true = Enum.all?(secret_names, &(System.get_env(&1) == nil))

receive_frame = fn receive_frame, socket, expected_type ->
  receive do
    {:tcp, ^socket, <<^expected_type, payload::binary>>} -> payload
    {:tcp, ^socket, _other} -> receive_frame.(receive_frame, socket, expected_type)
  after
    5_000 -> raise "holder frame timeout"
  end
end

{:ok, socket, true} = Holder.attach_or_spawn(id, [])
hello = receive_frame.(receive_frame, socket, Holder.type_hello()) |> Jason.decode!()
:ok = Holder.send_text_snapshot_req(socket, 200, 65_536)
snapshot = receive_frame.(receive_frame, socket, Holder.type_text_snapshot()) |> Jason.decode!()
true = Enum.any?(snapshot["lines"], &String.contains?(&1, marker))
:gen_tcp.close(socket)
File.write!(result_path, Jason.encode!(%{reattached: true, marker_preserved: true, shell_pid: hello["pid"]}))
'@
  $reattachSource = $reattachSource.Replace("__SESSION_ID__", ($sessionId | ConvertTo-Json -Compress))
  $reattachSource = $reattachSource.Replace("__MARKER__", ($marker | ConvertTo-Json -Compress))
  $reattachSource = $reattachSource.Replace("__RESULT_PATH__", ($resultFile | ConvertTo-Json -Compress))
  Invoke-ReleaseRpc $newBatch $reattachSource

  $reattachResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
  Assert-True ($reattachResult.reattached -and $reattachResult.marker_preserved) "New release did not reattach the preserved holder"
  Assert-True ([uint32]$reattachResult.shell_pid -eq $shellPid) "Shell PID changed on reattach"

  $normalNewAction = New-ScheduledTaskAction -Execute $newLauncher -Argument "`"$runner`" `"$logFile`""
  Set-ScheduledTask -TaskName $taskName -Action $normalNewAction | Out-Null
  Assert-TaskAction $taskName $newLauncher $runner $logFile

  $elevatedPrincipal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Highest
  Set-ScheduledTask -TaskName $taskName -Principal $elevatedPrincipal | Out-Null
  $elevatedTaskRejected = $false
  try { & $uninstall -PurgeData } catch {
    if ($_.Exception.Message -notmatch "not owned by this Dala installation") { throw }
    $elevatedTaskRejected = $true
  }
  Assert-True $elevatedTaskRejected "Uninstaller accepted an elevated Dala-looking task"
  Assert-True (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) "Principal guard removed the task"
  Assert-True (Test-Path -LiteralPath $installRoot -PathType Container) "Principal guard modified the installation"
  $limitedPrincipal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
  Set-ScheduledTask -TaskName $taskName -Principal $limitedPrincipal | Out-Null
  Assert-TaskAction $taskName $newLauncher $runner $logFile

  $foreignUninstallErl = Start-ForeignErl $expandedNew (Join-Path $installRoot "versions\v0.0.0\same-root-bait")
  $foreignUninstallErlPid = [uint32]$foreignUninstallErl.Id
  $lifecycleAppData = $env:APPDATA
  $lifecycleDiscoveryFile = $env:DALA_DISCOVERY_FILE
  $env:APPDATA = $scheduledAppData
  $env:DALA_DISCOVERY_FILE = $scheduledDiscoveryFile
  try {
    & $uninstall -PurgeData
  } finally {
    $env:APPDATA = $lifecycleAppData
    $env:DALA_DISCOVERY_FILE = $lifecycleDiscoveryFile
  }
  foreach ($processId in @($holderPid, $shellPid)) {
    Assert-True (-not (Get-Process -Id $processId -ErrorAction SilentlyContinue)) "Purge left terminal process $processId running"
  }
  Assert-True (Get-Process -Id $foreignUninstallErlPid -ErrorAction SilentlyContinue) "Uninstaller killed an unrelated sibling-root Erl process"
  Stop-Process -Id $foreignUninstallErlPid -Force -ErrorAction SilentlyContinue
  $foreignUninstallErlPid = $null
  Assert-True (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) "Purge left the Scheduled Task behind"
  foreach ($path in @($installRoot, $dataDir, $configFile, $discoveryFile, $discoveryDir)) {
    Assert-True (-not (Test-Path -LiteralPath $path)) "Purge left $path behind"
  }
  Assert-True (Test-Path -LiteralPath $scheduledDiscoveryFile -PathType Leaf) `
    "Purge removed an unrelated scheduled-task APPDATA discovery file"
  Assert-True ((Get-Content -LiteralPath $scheduledDiscoveryFile -Raw) -ceq $scheduledDiscoveryOriginal) `
    "Purge modified an unrelated scheduled-task APPDATA discovery file"
  Assert-True (Test-Path -LiteralPath $configDir -PathType Container) "Purge deleted the shared config directory"
  Assert-True (Test-Path -LiteralPath $unrelatedConfigFile -PathType Leaf) "Purge deleted an unrelated config-directory file"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $configDir ".dala-config"))) "Purge left a Dala marker in the shared config directory"

  $preserveRoot = Join-Path $smokeRoot "preserve install"
  $preserveData = Join-Path $smokeRoot "preserve data"
  $preserveAppData = Join-Path $smokeRoot "preserve appdata"
  $preserveConfigDir = Join-Path $preserveAppData "Dala"
  $preserveConfig = Join-Path $preserveConfigDir "config.jsonc"
  $preserveDiscovery = Join-Path $preserveConfigDir "install.json"
  $preserveTask = $taskName + "-preserve"
  New-Item -ItemType Directory -Force -Path (Join-Path $preserveRoot "versions\v0.0.1"), $preserveData, $preserveConfigDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $preserveRoot ".dala-install"), "Dala installation root`n")
  [IO.File]::WriteAllText((Join-Path $preserveData ".dala-data"), "Dala data directory`n")
  [IO.File]::WriteAllText((Join-Path $preserveConfigDir ".dala-config"), "Dala configuration directory`n")
  [IO.File]::WriteAllText((Join-Path $preserveRoot "current.txt"), "v0.0.1`n")
  [IO.File]::WriteAllText((Join-Path $preserveRoot "run-dala.ps1"), "# fixture`n")
  [IO.File]::WriteAllText((Join-Path $preserveData "secrets.json"), '{"keep":true}')
  [IO.File]::WriteAllText($preserveConfig, '{"server":true}')
  Write-InstallMetadata (Join-Path $preserveRoot "install.json") $preserveRoot $preserveData $preserveConfig $preserveTask $port
  Write-InstallMetadata $preserveDiscovery $preserveRoot $preserveData $preserveConfig $preserveTask $port

  $env:APPDATA = $preserveAppData
  $env:DALA_HOME = $preserveRoot
  $env:DALA_DATA_DIR = $preserveData
  $env:DALA_CONFIG = $preserveConfig
  $env:DALA_SERVICE = $preserveTask
  & $uninstall
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $preserveRoot "versions"))) "Non-purge uninstall kept versions"
  Assert-True (Test-Path -LiteralPath $preserveData -PathType Container) "Non-purge uninstall removed data"
  Assert-True (Test-Path -LiteralPath $preserveConfig -PathType Leaf) "Non-purge uninstall removed config"
  Assert-True (Test-Path -LiteralPath $preserveDiscovery -PathType Leaf) "Non-purge uninstall removed discovery metadata"
  & $uninstall -PurgeData
  foreach ($path in @($preserveRoot, $preserveData, $preserveConfigDir)) {
    Assert-True (-not (Test-Path -LiteralPath $path)) "Fixture purge left $path behind"
  }

  # APPDATA\Dala is a shared/default location.  Without the installer marker
  # an unrelated file must prevent directory removal, even when the metadata
  # and config file themselves look Dala-shaped.
  $unmarkedRoot = Join-Path $smokeRoot "unmarked-default install"
  $unmarkedData = Join-Path $smokeRoot "unmarked-default data"
  $unmarkedAppData = Join-Path $smokeRoot "unmarked-default appdata"
  $unmarkedConfigDir = Join-Path $unmarkedAppData "Dala"
  $unmarkedConfig = Join-Path $unmarkedConfigDir "config.jsonc"
  $unmarkedDiscovery = Join-Path $unmarkedConfigDir "install.json"
  $unmarkedUnrelated = Join-Path $unmarkedConfigDir "do-not-delete.txt"
  $unmarkedTask = $taskName + "-unmarked-default"
  New-Item -ItemType Directory -Force -Path $unmarkedRoot, $unmarkedData, $unmarkedConfigDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $unmarkedRoot ".dala-install"), "Dala installation root`n")
  [IO.File]::WriteAllText((Join-Path $unmarkedData ".dala-data"), "Dala data directory`n")
  [IO.File]::WriteAllText($unmarkedConfig, '{"server":true}')
  [IO.File]::WriteAllText($unmarkedUnrelated, "must survive default APPDATA purge`n")
  Write-InstallMetadata (Join-Path $unmarkedRoot "install.json") $unmarkedRoot $unmarkedData $unmarkedConfig $unmarkedTask $port
  Write-InstallMetadata $unmarkedDiscovery $unmarkedRoot $unmarkedData $unmarkedConfig $unmarkedTask $port
  $env:APPDATA = $unmarkedAppData
  $env:DALA_HOME = $unmarkedRoot
  $env:DALA_DATA_DIR = $unmarkedData
  $env:DALA_CONFIG = $unmarkedConfig
  $env:DALA_SERVICE = $unmarkedTask
  & $uninstall -PurgeData
  Assert-True (Test-Path -LiteralPath $unmarkedConfigDir -PathType Container) "Purge removed an unmarked default APPDATA directory"
  Assert-True (Test-Path -LiteralPath $unmarkedUnrelated -PathType Leaf) "Purge removed an unrelated default APPDATA file"
  Assert-True (-not (Test-Path -LiteralPath $unmarkedRoot)) "Purge left the unmarked install root behind"
  Assert-True (-not (Test-Path -LiteralPath $unmarkedData)) "Purge left the unmarked data directory behind"
  Assert-True (-not (Test-Path -LiteralPath $unmarkedConfig)) "Purge left the owned config file behind"
  Assert-True (-not (Test-Path -LiteralPath $unmarkedDiscovery)) "Purge left discovery metadata behind"

  $foreignRoot = Join-Path $smokeRoot "foreign task install"
  $foreignData = Join-Path $smokeRoot "foreign task data"
  $foreignAppData = Join-Path $smokeRoot "foreign task appdata"
  $foreignConfigDir = Join-Path $foreignAppData "Dala"
  $foreignConfig = Join-Path $foreignConfigDir "config.jsonc"
  $foreignDiscovery = Join-Path $foreignConfigDir "install.json"
  $foreignTaskName = $taskName + "-foreign"
  New-Item -ItemType Directory -Force -Path $foreignRoot, $foreignData, $foreignConfigDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $foreignRoot ".dala-install"), "Dala installation root`n")
  [IO.File]::WriteAllText((Join-Path $foreignData ".dala-data"), "Dala data directory`n")
  [IO.File]::WriteAllText((Join-Path $foreignConfigDir ".dala-config"), "Dala configuration directory`n")
  [IO.File]::WriteAllText($foreignConfig, '{"server":true}')
  Write-InstallMetadata (Join-Path $foreignRoot "install.json") $foreignRoot $foreignData $foreignConfig $foreignTaskName $port
  Write-InstallMetadata $foreignDiscovery $foreignRoot $foreignData $foreignConfig $foreignTaskName $port

  $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $foreignAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command exit"
  $foreignTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
  $foreignSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero)
  $foreignPrincipal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $foreignTaskName -Action $foreignAction -Trigger $foreignTrigger `
    -Settings $foreignSettings -Principal $foreignPrincipal -Force | Out-Null

  $env:APPDATA = $foreignAppData
  $env:DALA_HOME = $foreignRoot
  $env:DALA_DATA_DIR = $foreignData
  $env:DALA_CONFIG = $foreignConfig
  $env:DALA_SERVICE = $foreignTaskName
  $foreignTaskRejected = $false
  try { & $uninstall } catch {
    if ($_.Exception.Message -notmatch "not owned by this Dala installation") { throw }
    $foreignTaskRejected = $true
  }
  Assert-True $foreignTaskRejected "Uninstaller accepted a foreign Scheduled Task"
  Assert-True (Get-ScheduledTask -TaskName $foreignTaskName -ErrorAction SilentlyContinue) "Foreign task deletion guard removed the task"
  Unregister-ScheduledTask -TaskName $foreignTaskName -Confirm:$false
  $foreignTaskName = $null
  & $uninstall -PurgeData

  $env:APPDATA = $appDataRoot
  $env:DALA_HOME = Split-Path -Parent $env:LOCALAPPDATA
  $env:DALA_DATA_DIR = $dataDir
  $env:DALA_CONFIG = $configFile
  $env:DALA_SERVICE = $taskName + "-missing"
  $broadRootRejected = $false
  try { & $uninstall -PurgeData } catch {
    if ($_.Exception.Message -notmatch "sensitive directory or its ancestor") { throw }
    $broadRootRejected = $true
  }
  Assert-True $broadRootRejected "Sensitive-directory ancestor was accepted as DALA_HOME"

  $env:DALA_HOME = [IO.Path]::GetPathRoot($smokeRoot)
  $env:DALA_DATA_DIR = $dataDir
  $env:DALA_CONFIG = $configFile
  $env:DALA_SERVICE = $taskName + "-missing"
  $unsafeRootRejected = $false
  try { & $uninstall -PurgeData } catch {
    if ($_.Exception.Message -notmatch "Refusing to remove volume root") { throw }
    $unsafeRootRejected = $true
  }
  Assert-True $unsafeRootRejected "Volume-root uninstall target was accepted"

  $unverifiedRoot = Join-Path $smokeRoot "unverified custom root"
  New-Item -ItemType Directory -Force -Path $unverifiedRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $unverifiedRoot "keep.txt"), "must survive`n")
  $env:DALA_HOME = $unverifiedRoot
  $unverifiedRejected = $false
  try { & $uninstall -PurgeData } catch {
    if ($_.Exception.Message -notmatch "unverified DALA_HOME") { throw }
    $unverifiedRejected = $true
  }
  Assert-True $unverifiedRejected "Unverified custom uninstall root was accepted"
  Assert-True (Test-Path -LiteralPath (Join-Path $unverifiedRoot "keep.txt")) "Unverified custom root was modified"

  $directoryConfigRoot = Join-Path $smokeRoot "directory-config install"
  $directoryConfigData = Join-Path $smokeRoot "directory-config data"
  $directoryConfigAppData = Join-Path $smokeRoot "directory-config appdata"
  $directoryConfigDiscovery = Join-Path $directoryConfigAppData "Dala\install.json"
  $directoryConfigVictim = Join-Path $smokeRoot "directory passed as config file"
  $directoryConfigSentinel = Join-Path $directoryConfigVictim "must-survive.txt"
  $directoryConfigTask = $taskName + "-directory-config"
  New-Item -ItemType Directory -Force -Path $directoryConfigRoot, $directoryConfigData, $directoryConfigVictim | Out-Null
  [IO.File]::WriteAllText((Join-Path $directoryConfigRoot ".dala-install"), "Dala installation root`n")
  [IO.File]::WriteAllText((Join-Path $directoryConfigData ".dala-data"), "Dala data directory`n")
  [IO.File]::WriteAllText($directoryConfigSentinel, "must survive`n")
  Write-InstallMetadata (Join-Path $directoryConfigRoot "install.json") $directoryConfigRoot $directoryConfigData $directoryConfigVictim $directoryConfigTask $port
  Write-InstallMetadata $directoryConfigDiscovery $directoryConfigRoot $directoryConfigData $directoryConfigVictim $directoryConfigTask $port
  $env:APPDATA = $directoryConfigAppData
  $env:DALA_HOME = $directoryConfigRoot
  $env:DALA_DATA_DIR = $directoryConfigData
  $env:DALA_CONFIG = $directoryConfigVictim
  $env:DALA_SERVICE = $directoryConfigTask
  $directoryConfigRejected = $false
  try { & $uninstall -PurgeData } catch {
    if ($_.Exception.Message -notmatch "directory as the Dala config file") { throw }
    $directoryConfigRejected = $true
  }
  Assert-True $directoryConfigRejected "Purge accepted a directory as configFile"
  Assert-True (Test-Path -LiteralPath $directoryConfigSentinel -PathType Leaf) "Purge recursively deleted the configFile directory"

  # A marker file does not make a tree safe when one descendant is a junction.
  # The uninstaller must reject the whole purge before following it and leave
  # the external target untouched.
  $reparseRoot = Join-Path $smokeRoot "reparse install"
  $reparseData = Join-Path $smokeRoot "reparse data"
  $reparseAppData = Join-Path $smokeRoot "reparse appdata"
  $reparseConfigDir = Join-Path $reparseAppData "Dala"
  $reparseConfig = Join-Path $reparseConfigDir "config.jsonc"
  $reparseDiscovery = Join-Path $reparseConfigDir "install.json"
  $reparseTask = $taskName + "-reparse"
  $reparseVictim = Join-Path $smokeRoot "reparse victim"
  $reparseSentinel = Join-Path $reparseVictim "must-survive.txt"
  $reparseJunction = Join-Path $reparseRoot "versions"
  New-Item -ItemType Directory -Force -Path $reparseRoot, $reparseData, $reparseConfigDir, $reparseVictim | Out-Null
  [IO.File]::WriteAllText((Join-Path $reparseRoot ".dala-install"), "Dala installation root`n")
  [IO.File]::WriteAllText((Join-Path $reparseData ".dala-data"), "Dala data directory`n")
  [IO.File]::WriteAllText((Join-Path $reparseConfigDir ".dala-config"), "Dala configuration directory`n")
  [IO.File]::WriteAllText($reparseConfig, '{"server":true}')
  [IO.File]::WriteAllText($reparseSentinel, "must survive junction rejection`n")
  Write-InstallMetadata (Join-Path $reparseRoot "install.json") $reparseRoot $reparseData $reparseConfig $reparseTask $port
  Write-InstallMetadata $reparseDiscovery $reparseRoot $reparseData $reparseConfig $reparseTask $port
  $reparseVictimRelease = Join-Path $reparseVictim $newTag
  Write-DalaIdentityFixture $expandedNew $reparseVictimRelease $newVersion -Runnable
  New-Item -ItemType Junction -Path $reparseJunction -Target $reparseVictim | Out-Null
  $reparseRelease = Join-Path $reparseJunction $newTag
  $reparseErlProcess = Start-BootedErl $reparseRelease $newVersion $expandedNew
  $reparseErlPid = [uint32]$reparseErlProcess.Id
  $env:APPDATA = $reparseAppData
  $env:DALA_HOME = $reparseRoot
  $env:DALA_DATA_DIR = $reparseData
  $env:DALA_CONFIG = $reparseConfig
  $env:DALA_SERVICE = $reparseTask
  $reparseRejected = $false
  try { & $uninstall -PurgeData } catch {
    if ($_.Exception.Message -notmatch "reparse") { throw }
    $reparseRejected = $true
  }
  Assert-True $reparseRejected "Uninstaller followed a junction during purge"
  Assert-True (Test-Path -LiteralPath $reparseRoot -PathType Container) "Junction rejection removed the install root"
  Assert-True (Test-Path -LiteralPath $reparseSentinel -PathType Leaf) "Junction rejection removed the external target"
  Assert-True (Get-Process -Id $reparseErlPid -ErrorAction SilentlyContinue) `
    "Junction rejection killed an external release process before validation"
  [IO.Directory]::Delete($reparseJunction)
  Stop-Process -Id $reparseErlPid -Force -ErrorAction SilentlyContinue
  Wait-Process -Id $reparseErlPid -Timeout 10 -ErrorAction SilentlyContinue
  $reparseErlProcess = $null
  & $uninstall -PurgeData
  Assert-True (-not (Test-Path -LiteralPath $reparseRoot)) "Safe purge left the reparse install root behind"
  Assert-True (Test-Path -LiteralPath $reparseSentinel -PathType Leaf) "Safe purge removed the external target"
  Remove-Item -LiteralPath $reparseVictim -Recurse -Force

  $summary = [pscustomobject]@{
    archive_sha256_verified = $true
    old_version = $oldVersion
    new_version = $newVersion
    scheduled_task_install = $true
    installer_rollback = $true
    sidebar_rollback = $true
    concurrent_update_rejected = $true
    concurrent_fresh_install_rejected = $true
    concurrent_uninstall_rejected = $true
    global_lifecycle_lock_cross_session = $true
    failure_safe_release_publish = $true
    publisher_orphan_rejected = $true
    failed_publish_preserved_destination = $true
    complete_publish_winner_preserved = $true
    mismatched_publish_version_replaced = $true
    stale_update_rejected = $true
    update_results_correlated_by_attempt = $true
    noncanonical_attempt_id_rejected = $true
    fresh_health_decoy_rejected = $freshHealthRejected
    failed_release_stop_preserved_install = $stopFailureRejected
    update_health_decoy_rolled_back = (-not $healthDecoyResult.success -and $healthDecoyResult.rolled_back)
    rollback_cas_preserved_external_change = $true
    failed_rollback_runner_backup_retained = $true
    successful_update = $true
    holder_pid_preserved = $true
    shell_pid_preserved = $true
    secrets_absent_from_environment = $true
    purge_killed_live_session = $true
    non_purge_preserved_data = $true
    install_metadata_conflict_rejected = $installConflictRejected
    root_discovery_mismatch_rejected = $metadataMismatchRejected
    install_artifact_rollback = $precommitRollbackRejected
    installer_marker_reparse_rejected = $true
    config_port_synced_to_metadata = $true
    canonical_discovery_path_authoritative = $true
    ambient_discovery_decoy_preserved = $true
    uninstall_metadata_conflict_rejected = $uninstallConflictRejected
    foreign_task_rejected = $foreignTaskRejected
    elevated_task_rejected = $elevatedTaskRejected
    shared_config_directory_preserved = $true
    directory_config_rejected = $directoryConfigRejected
    sibling_process_boundaries_preserved = $true
    broad_root_rejected = $broadRootRejected
    unsafe_root_rejected = $unsafeRootRejected
    unverified_custom_root_rejected = $unverifiedRejected
    reparse_tree_rejected = $reparseRejected
    reparse_process_preserved = $true
  }
} finally {
  Stop-VersionDecoy $freshDecoyProcess
  Stop-VersionDecoy $updateDecoyProcess
  if ($reparseErlProcess -and -not $reparseErlProcess.HasExited) {
    Stop-Process -Id $reparseErlProcess.Id -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $reparseErlProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
  }
  foreach ($processId in @($wmiLockPid, $staleLockPid)) {
    if ($processId) {
      Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
      Wait-Process -Id $processId -Timeout 10 -ErrorAction SilentlyContinue
    }
  }
  Stop-ScheduledTask -TaskName $freshDecoyTask -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $freshDecoyTask -Confirm:$false -ErrorAction SilentlyContinue
  Stop-ScheduledTask -TaskName $stopFailureTask -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $stopFailureTask -Confirm:$false -ErrorAction SilentlyContinue
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  if ($foreignTaskName) {
    Stop-ScheduledTask -TaskName $foreignTaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $foreignTaskName -Confirm:$false -ErrorAction SilentlyContinue
  }

  $beamProcesses = @(Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$smokeRoot*" })
  $knownProcessIds = [Collections.Generic.List[uint32]]::new()
  foreach ($process in $beamProcesses) {
    $knownProcessIds.Add([uint32]$process.ProcessId)
  }
  foreach ($processId in @($holderPid, $shellPid, $foreignUpdateErlPid, $foreignUninstallErlPid)) {
    if ($processId) { $knownProcessIds.Add([uint32]$processId) }
  }
  if ($reparseErlProcess) { $knownProcessIds.Add([uint32]$reparseErlProcess.Id) }
  Stop-SmokeProcesses $smokeRoot $knownProcessIds

  foreach ($name in $environmentNames) {
    [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name], "Process")
  }

  $cleanupError = $null
  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if (-not (Test-Path -LiteralPath $smokeRoot)) { break }
    try {
      Remove-SmokeTree $smokeRoot
      $cleanupError = $null
    } catch {
      $cleanupError = $_.Exception.Message
    }
    if (Test-Path -LiteralPath $smokeRoot) { Start-Sleep -Milliseconds 100 }
  }
  if (Test-Path -LiteralPath $smokeRoot) {
    $remaining = @(
      Get-ChildItem -LiteralPath $smokeRoot -Force -ErrorAction SilentlyContinue |
        Select-Object -First 20 -ExpandProperty FullName
    )
    $detail = if ($cleanupError) { "; last cleanup error: $cleanupError" } else { "" }
    throw "Could not clean smoke root: $smokeRoot$detail; remaining: $($remaining -join ', ')"
  }
}

$summary | ConvertTo-Json -Compress
