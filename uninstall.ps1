[CmdletBinding()]
param([switch]$PurgeData)

$ErrorActionPreference = "Stop"
$TagPattern = '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
$DefaultRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Dala"
$DefaultDataDir = Join-Path $DefaultRoot "data"
$DefaultConfigDir = Join-Path $env:APPDATA "Dala"
$DiscoveryFile = Join-Path $DefaultConfigDir "install.json"

function Read-InstallMetadata([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

  try {
    $metadata = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($name in @("schemaVersion", "root", "dataDir", "configFile", "taskName", "port", "repo", "platform")) {
      if ($metadata.PSObject.Properties.Name -notcontains $name) { throw "required field '$name' is missing" }
    }
    if ([int]$metadata.schemaVersion -ne 1) { throw "unsupported schemaVersion" }
    foreach ($name in @("root", "dataDir", "configFile", "taskName", "repo", "platform")) {
      if ([string]::IsNullOrWhiteSpace([string]$metadata.$name)) { throw "field '$name' is empty" }
    }
    if ([int]$metadata.port -lt 1 -or [int]$metadata.port -gt 65535) { throw "invalid port" }
    if ([string]$metadata.platform -ne "windows-x86_64") { throw "unsupported platform" }
    $metadata
  } catch {
    throw "Invalid Dala install metadata at $Path`: $($_.Exception.Message)"
  }
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-InstallMetadataMatch($Left, $Right) {
  foreach ($name in @("root", "dataDir", "configFile")) {
    if (-not (Test-SamePath ([string]$Left.$name) ([string]$Right.$name))) {
      throw "Dala discovery and root install metadata disagree on $name"
    }
  }
  foreach ($name in @("taskName", "repo", "platform")) {
    if ([string]$Left.$name -cne [string]$Right.$name) {
      throw "Dala discovery and root install metadata disagree on $name"
    }
  }
  if ([int]$Left.port -ne [int]$Right.port) {
    throw "Dala discovery and root install metadata disagree on port"
  }
}

function Enter-LifecycleLock {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $name = "Global\DalaLifecycle-" + ($sid.Value -replace '[^0-9A-Za-z_-]', '_')
  $created = $false
  $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
  try {
    if (-not $mutex.WaitOne(0)) {
      $mutex.Dispose()
      throw "another Dala install or update is already in progress"
    }
  } catch [Threading.AbandonedMutexException] {
    # WaitOne grants ownership when the previous process exited unexpectedly.
  } catch {
    $mutex.Dispose()
    throw
  }
  $mutex
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

function Assert-TaskName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 238 -or
      $Name -match '[\\/:*?"<>|\[\]]' -or $Name -match '[\r\n]' -or $Name.Trim() -cne $Name) {
    throw "Invalid Scheduled Task name: $Name"
  }
}

function Get-SafeRemovalTarget([string]$Path, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty" }

  $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]"\/")
  $volume = [IO.Path]::GetPathRoot($full).TrimEnd([char[]]"\/")
  if ($full.Equals($volume, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove volume root for $Label`: $full"
  }

  $sensitiveDirectories = @(
    $env:USERPROFILE,
    $env:LOCALAPPDATA,
    $env:APPDATA,
    [IO.Path]::GetTempPath(),
    $env:SystemRoot,
    $env:ProgramFiles,
    [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"),
    $env:ProgramData
  )
  foreach ($sensitive in $sensitiveDirectories) {
    if (-not [string]::IsNullOrWhiteSpace($sensitive)) {
      $normalized = [IO.Path]::GetFullPath($sensitive).TrimEnd([char[]]"\/")
      $candidatePrefix = $full + [IO.Path]::DirectorySeparatorChar
      if ($full.Equals($normalized, [StringComparison]::OrdinalIgnoreCase) -or
          $normalized.StartsWith($candidatePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove sensitive directory or its ancestor for $Label`: $full"
      }
    }
  }

  $full
}

function Assert-DalaRoot([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if ((Test-SamePath $Path $DefaultRoot) -or
      (Test-Path -LiteralPath (Join-Path $Path ".dala-install") -PathType Leaf)) { return }
  throw "Refusing to remove unverified DALA_HOME: $Path"
}

function Assert-DalaDataDir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if ((Test-SamePath $Path $DefaultDataDir) -or
      (Test-Path -LiteralPath (Join-Path $Path ".dala-data") -PathType Leaf)) { return }
  throw "Refusing to remove unverified DALA_DATA_DIR: $Path"
}

function Test-RemovableDalaConfigDir([string]$Path, [string]$OwnedConfigFile, [string]$OwnedDiscoveryFile) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }

  if (-not (Test-NoReparseAncestors $Path)) { return $false }

  $marker = Join-Path $Path ".dala-config"
  if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }

  try {
    if (([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      return $false
    }
  } catch {
    return $false
  }

  $allowed = @{}
  foreach ($ownedPath in @($OwnedConfigFile, $OwnedDiscoveryFile, $marker)) {
    if ([string]::IsNullOrWhiteSpace([string]$ownedPath)) { continue }
    $full = [IO.Path]::GetFullPath($ownedPath).TrimEnd([char[]]"\/")
    $allowed[$full.ToLowerInvariant()] = $true
  }
  foreach ($entry in Get-ChildItem -LiteralPath $Path -Force) {
    $full = [IO.Path]::GetFullPath($entry.FullName).TrimEnd([char[]]"\/")
    if (-not $allowed.ContainsKey($full.ToLowerInvariant())) { return $false }
  }

  $true
}

function Test-NoReparseAncestors([string]$Path) {
  try {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }

    $current = $root
    $remainder = $full.Substring($root.Length)
    foreach ($segment in @($remainder -split '[\\/]')) {
      if ([string]::IsNullOrEmpty($segment)) { continue }
      $current = Join-Path $current $segment
      if (-not (Test-Path -LiteralPath $current)) { break }
      if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
      }
    }
    $true
  } catch {
    $false
  }
}

function Assert-NoReparseTree([string]$Path, [string]$Label) {
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to remove $Label through a reparse point: $Path"
  }
  if (-not (Test-Path -LiteralPath $Path)) { return }

  try {
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to remove $Label reparse point: $Path"
    }
    if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) { return }

    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
      $childAttributes = [IO.File]::GetAttributes($entry.FullName)
      if (($childAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove $Label containing a reparse point: $($entry.FullName)"
      }
      if (($childAttributes -band [IO.FileAttributes]::Directory) -ne 0) {
        Assert-NoReparseTree $entry.FullName $Label
      }
    }
  } catch {
    if ($_.Exception.Message -like "Refusing to remove*") { throw }
    throw "Could not inspect $Label safely: $($_.Exception.Message)"
  }
}

function Get-CurrentExecutable([string]$InstallRoot) {
  $current = Join-Path $InstallRoot "current.txt"
  if (-not (Test-Path -LiteralPath $current -PathType Leaf)) { return $null }
  if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Dala version pointer is a reparse point: $current"
  }

  $tag = (Get-Content -LiteralPath $current -Raw).Trim()
  if ($tag -cnotmatch $TagPattern) {
    throw "Invalid Dala version pointer: $tag"
  }

  $candidate = Join-Path $InstallRoot "versions\$tag\bin\dala.bat"
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
  if (([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Dala release executable is a reparse point: $candidate"
  }
  [IO.Path]::GetFullPath($candidate)
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
      ReleaseDir = $releaseDir
      Version = $version
      Executable = [IO.Path]::GetFullPath($expected)
      Boot = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start"))
      BootFile = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start.boot"))
    }
  } catch {
    $null
  }
}

function Assert-DalaTaskOwnership($Task, [string]$InstallRoot) {
  Assert-DalaTaskPrincipal $Task
  $actions = @($Task.Actions)
  $runner = Join-Path $InstallRoot "run-dala.ps1"
  $logFile = Join-Path $InstallRoot "logs\server.log"
  $expectedArguments = "`"$runner`" `"$logFile`""

  $current = Join-Path $InstallRoot "current.txt"
  if (-not (Test-Path -LiteralPath $current -PathType Leaf)) {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }
  $tag = (Get-Content -LiteralPath $current -Raw).Trim()
  if ($tag -cnotmatch $TagPattern) {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }
  $version = $tag.Substring(1)
  $launcher = Join-Path $InstallRoot "versions\$tag\lib\dala-$version\priv\bin\dala_task_launcher.exe"
  if ((Test-Path -LiteralPath $launcher -PathType Leaf) -and
      (([IO.File]::GetAttributes($launcher) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }
  $ownedLauncher = $actions.Count -eq 1 -and
    (Test-Path -LiteralPath $launcher -PathType Leaf) -and
    (Test-SamePath ([string]$actions[0].Execute) $launcher)

  if (-not $ownedLauncher -or [string]$actions[0].Arguments -cne $expectedArguments) {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }
}

function Get-ReleaseBeamProcesses([string]$InstallRoot) {
  $identities = @()
  $versionsRoot = Join-Path $InstallRoot "versions"
  if (Test-Path -LiteralPath $versionsRoot -PathType Container) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
      if ($directory.Name -cmatch $TagPattern) {
        $candidate = Join-Path $directory.FullName "bin\dala.bat"
        $identity = Get-ReleaseIdentity $candidate
        if ($identity) { $identities += $identity }
      }
    }
  }
  if ($identities.Count -eq 0) { return @() }
  @(
    Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $processExecutable = [string]$_.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($processExecutable)) { return $false }
        $identity = $null
        foreach ($candidateIdentity in $identities) {
          if (Test-SamePath $processExecutable $candidateIdentity.Executable) {
            $identity = $candidateIdentity
            break
          }
        }
        if (-not $identity) { return $false }
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

function Stop-DalaRelease([string]$InstallRoot, [string]$Executable) {
  if ($Executable) { & $Executable stop 2>$null | Out-Null }

  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if ((Get-ReleaseBeamProcesses $InstallRoot).Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }

  foreach ($process in Get-ReleaseBeamProcesses $InstallRoot) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if ((Get-ReleaseBeamProcesses $InstallRoot).Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }

  throw "Dala release processes did not stop under $InstallRoot"
}

function Get-ScopedHolders([string]$InstallRoot) {
  $holderPaths = @()
  $versionsRoot = Join-Path $InstallRoot "versions"
  if (Test-Path -LiteralPath $versionsRoot -PathType Container) {
    foreach ($directory in @(Get-ChildItem -LiteralPath $versionsRoot -Directory -Force -ErrorAction SilentlyContinue)) {
      if ($directory.Name -cnotmatch $TagPattern) { continue }
      $version = $directory.Name.Substring(1)
      foreach ($name in @("dala_holder.exe")) {
        $candidate = Join-Path $directory.FullName "lib\dala-$version\priv\bin\$name"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $holderPaths += [IO.Path]::GetFullPath($candidate)
        }
      }
    }
  }
  if ($holderPaths.Count -eq 0) { return @() }

  @(
    Get-CimInstance Win32_Process -Filter "Name='dala_holder.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $path = [string]$_.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        foreach ($holderPath in $holderPaths) {
          if (Test-SamePath $path $holderPath) { return $true }
        }
        $false
      }
  )
}

function Get-ProcessTreeIds($Processes, [uint32[]]$RootIds) {
  $ids = @{}
  foreach ($rootId in $RootIds) { $ids[[string]$rootId] = $true }

  do {
    $added = $false
    foreach ($process in $Processes) {
      $pidKey = [string][uint32]$process.ProcessId
      $parentKey = [string][uint32]$process.ParentProcessId
      if ($ids.ContainsKey($parentKey) -and -not $ids.ContainsKey($pidKey)) {
        $ids[$pidKey] = $true
        $added = $true
      }
    }
  } while ($added)

  @($ids.Keys | ForEach-Object { [uint32]$_ })
}

function Stop-ScopedHolders([string]$InstallRoot) {
  $holders = @(Get-ScopedHolders $InstallRoot)
  if ($holders.Count -eq 0) { return @() }

  $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $holderIds = @($holders | ForEach-Object { [uint32]$_.ProcessId })
  $treeIds = @(Get-ProcessTreeIds $snapshot $holderIds)

  foreach ($processId in $treeIds) {
    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
  }

  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    $remaining = @($treeIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($remaining.Count -eq 0 -and (Get-ScopedHolders $InstallRoot).Count -eq 0) {
      return $treeIds
    }
    Start-Sleep -Milliseconds 100
  }

  $remaining = @($treeIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
  throw "Installation-scoped terminal processes did not stop: $($remaining -join ', ')"
}

function Remove-RequiredPath([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }

  $lastError = $null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      Assert-NoReparseTree $Path "Dala removal target"
      Remove-SafeTree $Path
      $lastError = $null
    } catch {
      $lastError = $_.Exception.Message
      if ($lastError -like "Refusing to remove*") { throw $lastError }
    }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Start-Sleep -Milliseconds 100
  }

  throw "Could not remove $Path$(if ($lastError) { ": $lastError" })"
}

function Remove-SafeTree([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to remove through a reparse point: $Path"
  }

  $attributes = [IO.File]::GetAttributes($Path)
  if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove a reparse point: $Path"
  }

  if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
      $childAttributes = [IO.File]::GetAttributes($entry.FullName)
      if (($childAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a reparse point: $($entry.FullName)"
      }
      Remove-SafeTree $entry.FullName
    }

    # Re-check immediately before the non-recursive delete in case a child
    # was replaced with a junction while the tree was being traversed.
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to remove a reparse point: $Path"
    }
    if (-not (Test-NoReparseAncestors $Path)) {
      throw "Refusing to remove through a reparse point: $Path"
    }
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
    [IO.Directory]::Delete($Path)
  } else {
    if (-not (Test-NoReparseAncestors $Path)) {
      throw "Refusing to remove through a reparse point: $Path"
    }
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
    [IO.File]::Delete($Path)
  }
}

function Remove-OwnedConfigFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (Test-Path -LiteralPath $Path -PathType Container) {
    throw "Refusing to remove a directory as the Dala config file: $Path"
  }
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to remove the Dala config file through a reparse point: $Path"
  }
  if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove a reparse-point Dala config file: $Path"
  }

  [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
  [IO.File]::Delete($Path)
  if (Test-Path -LiteralPath $Path) { throw "Could not remove Dala config file: $Path" }
}

$LifecycleLock = Enter-LifecycleLock
try {
$discoveryMetadata = Read-InstallMetadata $DiscoveryFile
$rootHint = if ($env:DALA_HOME) {
  $env:DALA_HOME
} elseif ($discoveryMetadata) {
  [string]$discoveryMetadata.root
} else {
  $DefaultRoot
}
$rootMetadata = Read-InstallMetadata (Join-Path ([IO.Path]::GetFullPath($rootHint)) "install.json")
if ($discoveryMetadata -and $rootMetadata) {
  Assert-InstallMetadataMatch $discoveryMetadata $rootMetadata
}
$metadata = if ($rootMetadata) { $rootMetadata } else { $discoveryMetadata }

$Root = if ($env:DALA_HOME) { $env:DALA_HOME } elseif ($metadata) { [string]$metadata.root } else { $DefaultRoot }
$DataDir = if ($env:DALA_DATA_DIR) { $env:DALA_DATA_DIR } elseif ($metadata) { [string]$metadata.dataDir } else { $DefaultDataDir }
$TaskName = if ($env:DALA_SERVICE) { $env:DALA_SERVICE } elseif ($metadata) { [string]$metadata.taskName } else { "Dala" }
Assert-TaskName $TaskName
$ConfigFile = if ($env:DALA_CONFIG) {
  $env:DALA_CONFIG
} elseif ($metadata) {
  [string]$metadata.configFile
} elseif (Test-Path -LiteralPath (Join-Path $DefaultConfigDir "config.jsonc") -PathType Leaf) {
  Join-Path $DefaultConfigDir "config.jsonc"
} else {
  Join-Path $DefaultConfigDir "dala.env"
}

$Root = Get-SafeRemovalTarget $Root "DALA_HOME"
$DataDir = Get-SafeRemovalTarget $DataDir "DALA_DATA_DIR"
$ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
$ConfigDir = [IO.Path]::GetFullPath((Split-Path -Parent $ConfigFile)).TrimEnd([char[]]"\/")
$ConfigMarker = Join-Path $ConfigDir ".dala-config"

if ($metadata -and -not (Test-SamePath $Root ([string]$metadata.root))) {
  throw "DALA_HOME conflicts with Dala install metadata"
}
if ($metadata) {
  if ($env:DALA_DATA_DIR -and -not (Test-SamePath $DataDir ([string]$metadata.dataDir))) {
    throw "DALA_DATA_DIR conflicts with Dala install metadata"
  }
  if ($env:DALA_CONFIG -and -not (Test-SamePath $ConfigFile ([string]$metadata.configFile))) {
    throw "DALA_CONFIG conflicts with Dala install metadata"
  }
  if ($env:DALA_SERVICE -and [string]$TaskName -cne [string]$metadata.taskName) {
    throw "DALA_SERVICE conflicts with Dala install metadata"
  }
  if ($env:DALA_PORT) {
    try { $requestedPort = [int]$env:DALA_PORT } catch { throw "DALA_PORT conflicts with Dala install metadata" }
    if ($requestedPort -ne [int]$metadata.port) { throw "DALA_PORT conflicts with Dala install metadata" }
  }
  if ($env:DALA_REPO -and [string]$env:DALA_REPO -cne [string]$metadata.repo) {
    throw "DALA_REPO conflicts with Dala install metadata"
  }
  if ([string]$metadata.platform -cne "windows-x86_64") {
    throw "platform conflicts with Dala install metadata"
  }
}

$configOwnedByMetadata = $metadata -and
  (Test-SamePath $Root ([string]$metadata.root)) -and
  (Test-SamePath $ConfigFile ([string]$metadata.configFile))
$configOwned = $configOwnedByMetadata -or (Test-Path -LiteralPath $ConfigMarker -PathType Leaf)
$discoveryOwned = $false
if ($discoveryMetadata) {
  $discoveryOwned = (Test-SamePath $Root ([string]$discoveryMetadata.root)) -and
    (Test-SamePath $ConfigFile ([string]$discoveryMetadata.configFile))
}

if ($PurgeData -and (Test-Path -LiteralPath $ConfigFile -PathType Container)) {
  throw "Refusing to remove a directory as the Dala config file: $ConfigFile"
}
Assert-DalaRoot $Root
$ConfigDirRemovalTarget = $null
$DiscoveryDirRemovalTarget = $null
if ($PurgeData) {
  Assert-DalaDataDir $DataDir
  if (Test-Path -LiteralPath $DataDir) {
    Assert-NoReparseTree $DataDir "Dala data directory"
  }
  $ownedConfigPath = if ($configOwned) { $ConfigFile } else { $null }
  $ownedDiscoveryPath = if ($discoveryOwned) { $DiscoveryFile } else { $null }
  if (Test-RemovableDalaConfigDir $ConfigDir $ownedConfigPath $ownedDiscoveryPath) {
    $ConfigDirRemovalTarget = Get-SafeRemovalTarget $ConfigDir "config directory"
  }
  if (Test-RemovableDalaConfigDir $DefaultConfigDir $ownedConfigPath $ownedDiscoveryPath) {
    $DiscoveryDirRemovalTarget = Get-SafeRemovalTarget $DefaultConfigDir "config discovery directory"
  }
}

# Validate the release tree before resolving version identities or enumerating
# processes.  A junction under `versions` must never redirect process matching
# into an external directory before the later removal guard gets a chance to
# reject it.
if (-not (Test-NoReparseAncestors $Root)) {
  throw "Refusing to inspect Dala releases through a reparse point: $Root"
}
$versionsRoot = Join-Path $Root "versions"
if (Test-Path -LiteralPath $versionsRoot) {
  Assert-NoReparseTree $versionsRoot "Dala release tree"
}

$currentExecutable = Get-CurrentExecutable $Root
$tasks = @(Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue)
if ($tasks.Count -gt 1) { throw "Multiple root Scheduled Tasks match '$TaskName'" }
$task = if ($tasks.Count -eq 1) { $tasks[0] } else { $null }
if ($task) {
  Assert-DalaTaskOwnership $task $Root
  Stop-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
}
Stop-DalaRelease $Root $currentExecutable

if ($task) {
  Unregister-ScheduledTask -TaskName $TaskName -TaskPath "\" -Confirm:$false -ErrorAction Stop
  if (Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue) {
    throw "Scheduled task still exists after uninstall: $TaskName"
  }
}

$stoppedTerminalPids = @(Stop-ScopedHolders $Root)
if ((Get-ScopedHolders $Root).Count -ne 0) {
  throw "Dala terminal holders are still running under $Root"
}

if ($PurgeData) {
  if ($discoveryOwned) {
    Remove-OwnedConfigFile $DiscoveryFile
  }
  if ($configOwned) {
    Remove-OwnedConfigFile $ConfigFile
  }
  if (-not $ConfigDirRemovalTarget) {
    $markerPath = Join-Path $ConfigDir ".dala-config"
    if (Test-Path -LiteralPath $markerPath) {
      Remove-OwnedConfigFile $markerPath
    }
  }

  $targets = @{}
  foreach ($target in @($Root, $DataDir, $ConfigDirRemovalTarget, $DiscoveryDirRemovalTarget) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) {
    $full = [IO.Path]::GetFullPath($target).TrimEnd([char[]]"\/")
    $targets[$full.ToLowerInvariant()] = $full
  }
  foreach ($target in @($targets.Values | Sort-Object { $_.Length } -Descending)) {
    Remove-RequiredPath $target
  }

  $ownedConfigCheck = if ($configOwned) { $ConfigFile } else { $null }
  $ownedDiscoveryCheck = if ($discoveryOwned) { $DiscoveryFile } else { $null }
  foreach ($target in @($Root, $DataDir, $ownedConfigCheck, $ownedDiscoveryCheck, $ConfigDirRemovalTarget, $DiscoveryDirRemovalTarget) |
      Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) {
    if (Test-Path -LiteralPath $target) { throw "Purge left $target behind" }
  }

  Write-Host "Dala, its configuration, and its data were removed."
} else {
  foreach ($target in @(
    (Join-Path $Root "versions"),
    (Join-Path $Root "current.txt"),
    (Join-Path $Root "run-dala.ps1"),
    (Join-Path $Root "logs")
  )) {
    Remove-RequiredPath $target
  }
  foreach ($entry in @(Get-ChildItem -LiteralPath $Root -Filter ".current-*.new" -Force -ErrorAction SilentlyContinue)) {
    Remove-RequiredPath $entry.FullName
  }
  foreach ($entry in @(Get-ChildItem -LiteralPath $Root -Filter ".run-dala-*" -Force -ErrorAction SilentlyContinue)) {
    Remove-RequiredPath $entry.FullName
  }

  foreach ($target in @((Join-Path $Root "versions"), (Join-Path $Root "current.txt"), (Join-Path $Root "run-dala.ps1"))) {
    if (Test-Path -LiteralPath $target) { throw "Uninstall left $target behind" }
  }

  Write-Host "Dala was removed. Configuration and data remain; use -PurgeData to remove them."
}
} finally {
  if ($LifecycleLock) {
    $LifecycleLock.ReleaseMutex()
    $LifecycleLock.Dispose()
    $LifecycleLock = $null
  }
}

return
