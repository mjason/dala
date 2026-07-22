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

function Assert-ScriptParses([string]$Path) {
  $tokens = $null
  $errors = $null
  $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    $details = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join "; "
    throw "PowerShell parser rejected $Path`: $details"
  }
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
    $expectedBoot = Join-Path $ReleaseDir "releases\$Version\start"
    $expectedBootFile = Join-Path $ReleaseDir "releases\$Version\start.boot"
    Assert-True (Test-SamePath ([string]$identity.Executable) $expectedErl) `
      "$ScriptPath resolved the wrong erl.exe from bin\dala.bat"
    Assert-True (Test-SamePath ([string]$identity.Boot) $expectedBoot) `
      "$ScriptPath resolved the wrong -boot path from bin\dala.bat"
    Assert-True (Test-SamePath ([string]$identity.BootFile) $expectedBootFile) `
      "$ScriptPath resolved the wrong start.boot path from bin\dala.bat"
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Write-DalaIdentityFixture([string]$SourceRelease, [string]$Destination, [string]$Version) {
  $startData = @((Get-Content -LiteralPath (Join-Path $SourceRelease "releases\start_erl.data") -Raw).Trim() -split '\s+')
  Assert-True ($startData.Count -eq 2 -and [string]$startData[1] -ceq $Version) `
    "Release fixture has malformed start_erl.data"

  foreach ($relative in @(
    "bin\dala.bat",
    "releases\start_erl.data",
    "releases\$Version\start.boot",
    "erts-$($startData[0])\bin\erl.exe"
  )) {
    $source = Join-Path $SourceRelease $relative
    Assert-True (Test-Path -LiteralPath $source -PathType Leaf) "Release fixture is missing $relative"
    $target = Join-Path $Destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
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
    $scriptBase = Join-Path $targetReleaseRoot $scriptName
    $scriptBase = $scriptBase.Replace('\', '/')
    $escapedScriptBase = $scriptBase.Replace('"', '\"')
    $eval = "case systools:script2boot(`"$escapedScriptBase`") of ok -> halt(0); Error -> io:format(standard_error, `"~p~n`", [Error]), halt(1) end."
    & $ErlPath -noshell -eval $eval
    if ($LASTEXITCODE -ne 0) { throw "Could not rebuild $scriptName.boot for fixture version $Version" }
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
    Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
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

function Wait-NoSmokeBeam([string]$InstallRoot) {
  for ($attempt = 0; $attempt -lt 150; $attempt++) {
    if (-not (Get-SmokeBeam $InstallRoot)) { return }
    Start-Sleep -Milliseconds 100
  }
  throw "Dala BEAM process did not stop under $InstallRoot"
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

function Start-BootedErl([string]$ReleaseDir, [string]$Version) {
  $startData = @((Get-Content -LiteralPath (Join-Path $ReleaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
  if ($startData.Count -ne 2 -or [string]$startData[1] -cne $Version) {
    throw "Release fixture has malformed start_erl.data: $ReleaseDir"
  }
  $erl = Join-Path $ReleaseDir "erts-$($startData[0])\bin\erl.exe"
  $boot = Join-Path $ReleaseDir "releases\$Version\start"
  $bootFile = "$boot.boot"
  if (-not (Test-Path -LiteralPath $erl -PathType Leaf) -or
      -not (Test-Path -LiteralPath $bootFile -PathType Leaf)) {
    throw "Release fixture is missing boot identity files: $ReleaseDir"
  }

  # Keep the identity-shaped -boot token in the command line without starting
  # the full release, whose application/config files are intentionally absent
  # from this reduced fixture. Everything after `-extra` is user data, so the
  # token remains visible to ownership checks without being parsed by Erlang.
  $arguments = "-noshell -eval `"timer:sleep(600000).`" -extra -boot `"$boot`""
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
$erl = @(
  Get-ChildItem -LiteralPath $releaseDir -Filter "erl.exe" -Recurse -File |
    Where-Object { $_.FullName -like "*\erts-*\bin\erl.exe" }
)
if ($erl.Count -ne 1) { throw "Expected one target erl.exe, found $($erl.Count)" }
& $erl[0].FullName -noshell -eval "timer:sleep(600000)."
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
  $client = $listener.AcceptTcpClient()
  try {
    $stream = $client.GetStream()
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
  [int]$Port
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
  Assert-True ([int]$config.port -eq $Port) "config.jsonc has the wrong port"
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
    Assert-True ([int]$metadata.port -eq $Port) "install.json has the wrong port"
    Assert-True ([string]$metadata.platform -ceq "windows-x86_64") "install.json has the wrong platform"
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
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  & $CurrentExecutable stop 2>$null | Out-Null
  Wait-NoSmokeBeam $InstallRoot
  $action = New-ScheduledTaskAction -Execute $Launcher -Argument "`"$Runner`" `"$LogFile`""
  Set-ScheduledTask -TaskName $TaskName -Action $action | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Wait-DalaVersion $Port $ExpectedVersion
}

function Invoke-ReleaseRpc([string]$Executable, [string]$Source) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Source))
  $expression = "Code.eval_string(Base.decode64!(`"$encoded`"))"
  $output = & $Executable rpc $expression 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "Release RPC failed: $output" }
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
Assert-InstallerJsoncSemantics $installer
Assert-ArchiveChecksum $archive $checksum

$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ("dala release smoke " + [guid]::NewGuid().ToString("N"))
$expandedNew = Join-Path $smokeRoot "expanded new"
$expandedOld = Join-Path $smokeRoot "expanded old"
$expandedDecoy = Join-Path $smokeRoot "expanded decoy"
$expandedIncomplete = Join-Path $smokeRoot "expanded incomplete"
$expandedStopFailure = Join-Path $smokeRoot "expanded stop failure"
$oldArchive = Join-Path $smokeRoot "dala-old-windows-x86_64.zip"
$oldChecksum = "$oldArchive.sha256"
$decoyArchive = Join-Path $smokeRoot "dala-decoy-windows-x86_64.zip"
$decoyChecksum = "$decoyArchive.sha256"
$stopFailureArchive = Join-Path $smokeRoot "dala-stop-failure-windows-x86_64.zip"
$stopFailureChecksum = "$stopFailureArchive.sha256"
$incompleteArchive = Join-Path $smokeRoot "dala-incomplete-windows-x86_64.zip"
$incompleteChecksum = "$incompleteArchive.sha256"
$installRoot = Join-Path $smokeRoot "install root"
$dataDir = Join-Path $smokeRoot "data dir"
$appDataRoot = Join-Path $smokeRoot "roaming app data"
$discoveryDir = Join-Path $appDataRoot "Dala"
$configDir = Join-Path $smokeRoot "shared config directory"
$configFile = Join-Path $configDir "dala-config.jsonc"
$unrelatedConfigFile = Join-Path $configDir "keep-me.txt"
$ambientRunnerConfig = Join-Path $smokeRoot "ambient foreign runner config.jsonc"
$discoveryFile = Join-Path $discoveryDir "install.json"
$taskName = "DalaReleaseSmoke-" + [guid]::NewGuid().ToString("N")
$port = Get-FreePort
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
while ($freshDecoyPort -eq $port) { $freshDecoyPort = Get-FreePort }
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
  "APPDATA", "DALA_HOME", "DALA_DATA_DIR", "DALA_CONFIG", "DALA_SERVICE", "DALA_PORT", "DALA_REPO",
  "RELEASE_NAME", "RELEASE_VSN", "RELEASE_MODE", "RELEASE_NODE", "RELEASE_COOKIE",
  "RELEASE_TMP", "RELEASE_VM_ARGS", "RELEASE_REMOTE_VM_ARGS", "RELEASE_DISTRIBUTION",
  "RELEASE_BOOT_SCRIPT", "RELEASE_BOOT_SCRIPT_CLEAN", "RELEASE_SYS_CONFIG", "RELEASE_ROOT",
  "RELEASE_COMMAND", "RELEASE_PROG", "RELEASE_MUTABLE_DIR", "RELEASE_READ_ONLY",
  "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS", "ERL_LIBS", "ERL_INETRC", "ELIXIR_ERL_OPTIONS",
  "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET",
  "DALA_SECRET_KEY_BASE", "DALA_TOKEN_SIGNING_SECRET"
)
$originalEnvironment = @{}
foreach ($name in $environmentNames) {
  $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

try {
  New-Item -ItemType Directory -Force -Path $smokeRoot, $expandedNew, $expandedOld, $expandedDecoy, $expandedIncomplete, `
    $expandedStopFailure, $configDir | Out-Null
  Assert-InstallerArchiveTypeSemantics $installer $smokeRoot
  Assert-PublisherSafeRemovalSemantics $publishHelperSource $smokeRoot
  [IO.File]::WriteAllText($unrelatedConfigFile, "must survive purge`n", [Text.UTF8Encoding]::new($false))
  Expand-Archive -LiteralPath $archive -DestinationPath $expandedNew -Force

  foreach ($required in @("bin\dala.bat", "run-dala.ps1")) {
    Assert-True (Test-Path -LiteralPath (Join-Path $expandedNew $required) -PathType Leaf) "Final ZIP is missing $required"
  }
  Assert-True (Get-TaskLauncher $expandedNew) "Final ZIP is missing dala_task_launcher.exe"
  Assert-True (Get-UpdateHelper $expandedNew) "Final ZIP is missing update-dala.ps1"

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
  $freshDecoyProcess = Start-VersionDecoy $freshDecoyPort $oldVersion
  $freshHealthRejected = $false
  $freshHealthMessage = $null
  try {
    & $installer -Version $oldTag -ArchivePath $decoyArchive -ChecksumPath $decoyChecksum `
      -ExpectedVersion $oldVersion -HealthTimeoutSeconds 5
  } catch {
    $freshHealthMessage = $_.Exception.Message
    $freshHealthRejected = $true
  } finally {
    try {
      Wait-VersionDecoyExited $freshDecoyProcess "Fresh-install version decoy"
    } finally {
      Stop-VersionDecoy $freshDecoyProcess
      $freshDecoyProcess = $null
    }
  }

  $freshTaskLeft = [bool](Get-ScheduledTask -TaskName $freshDecoyTask -ErrorAction SilentlyContinue)
  $freshCurrentLeft = Test-Path -LiteralPath (Join-Path $freshDecoyRoot "current.txt")
  $freshDiscoveryLeft = Test-Path -LiteralPath (Join-Path $freshDecoyAppData "Dala\install.json")
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
  Assert-True (-not $freshTaskLeft) "Fresh health rollback left the Scheduled Task behind"
  Assert-True (-not $freshCurrentLeft) "Fresh health rollback left current.txt behind"
  Assert-True (-not $freshDiscoveryLeft) "Fresh health rollback left discovery metadata behind"
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
  $env:DALA_PORT = [string]$port
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
  Wait-DalaVersion $port $oldVersion

  $oldDir = Join-Path $installRoot "versions\$oldTag"
  $oldBatch = Join-Path $oldDir "bin\dala.bat"
  $oldLauncher = Get-TaskLauncher $oldDir
  Assert-True $oldLauncher "Installed old release is missing dala_task_launcher.exe"
  Assert-TaskAction $taskName $oldLauncher $runner $logFile
  Assert-InstallContract $installRoot $dataDir $configFile $discoveryFile $taskName $port
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $configDir ".dala-config"))) "Installer claimed a shared config directory"
  Assert-True (Test-Path -LiteralPath $unrelatedConfigFile -PathType Leaf) "Installer modified the shared config directory"

  $rootMetadataFile = Join-Path $installRoot "install.json"
  $rootMetadataText = Get-Content -LiteralPath $rootMetadataFile -Raw
  Remove-Item -LiteralPath $discoveryFile -Force
  & $installer -Version $oldTag -ArchivePath $oldArchive -ChecksumPath $oldChecksum `
    -ExpectedVersion $oldVersion -HealthTimeoutSeconds 90
  Assert-True (Test-Path -LiteralPath $discoveryFile -PathType Leaf) "Installer did not recover missing discovery metadata"
  Assert-InstallContract $installRoot $dataDir $configFile $discoveryFile $taskName $port

  $mismatchedMetadata = $rootMetadataText | ConvertFrom-Json
  $mismatchedMetadata.port = $port + 1
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
  Wait-DalaVersion $port $oldVersion

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
  DALA_UPDATE_REPO DALA_SCHEME PHX_SCHEME DALA_POOL_SIZE POOL_SIZE
  RELEASE_NAME RELEASE_VSN RELEASE_MODE RELEASE_NODE RELEASE_COOKIE RELEASE_TMP
  RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS RELEASE_DISTRIBUTION RELEASE_BOOT_SCRIPT
  RELEASE_BOOT_SCRIPT_CLEAN RELEASE_SYS_CONFIG RELEASE_ROOT RELEASE_COMMAND RELEASE_PROG
  RELEASE_MUTABLE_DIR RELEASE_READ_ONLY ERL_FLAGS ERL_AFLAGS ERL_ZFLAGS ERL_LIBS
  ERL_INETRC ELIXIR_ERL_OPTIONS
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
    if ($_.Exception.Message -notmatch "previous release was restored") { throw }
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

  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  & $oldBatch stop 2>$null | Out-Null
  Wait-NoSmokeBeam $installRoot
  $targetRunnerPath = Join-Path $newDir "run-dala.ps1"
  $targetRunnerBody = Get-Content -LiteralPath $targetRunnerPath -Raw
  Write-DummyReleaseRunner $targetRunnerPath $newTag
  $updateDecoyProcess = Start-VersionDecoy $port $newVersion
  $healthDecoyAttemptId = New-SmokeAttemptId
  Remove-Item -LiteralPath $healthDecoyResultFile -Force -ErrorAction SilentlyContinue
  try {
    $healthDecoyOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $newHelper `
      -InstallRoot $installRoot -TaskName $taskName -TargetTag $newTag -PreviousTag $oldTag `
      -ExpectedVersion $newVersion -AttemptId $healthDecoyAttemptId `
      -ResultFile $healthDecoyResultFile -HealthTimeoutSeconds 5 2>&1 | Out-String
    $healthDecoyStatus = $LASTEXITCODE
  } finally {
    try {
      Wait-VersionDecoyExited $updateDecoyProcess "Update version decoy"
    } finally {
      Stop-VersionDecoy $updateDecoyProcess
      $updateDecoyProcess = $null
      [IO.File]::WriteAllText($targetRunnerPath, $targetRunnerBody, [Text.UTF8Encoding]::new($false))
    }
  }

  $healthDecoyResult = Get-Content -LiteralPath $healthDecoyResultFile -Raw | ConvertFrom-Json
  Assert-UpdateResultAttempt $healthDecoyResult $healthDecoyAttemptId
  Assert-True ($healthDecoyStatus -ne 0) "Update helper accepted a same-version response from a foreign port owner"
  Assert-True ($healthDecoyOutput -match "did not become healthy") "Update decoy failure returned the wrong error"
  Assert-True (-not $healthDecoyResult.success -and $healthDecoyResult.rolled_back) "Update decoy did not roll back"
  Assert-True (((Get-Content -LiteralPath (Join-Path $installRoot "current.txt") -Raw).Trim()) -ceq $oldTag) "Update decoy rollback did not restore current.txt"
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

  [IO.File]::WriteAllText((Join-Path $installRoot "current.txt"), "$newTag`n", [Text.UTF8Encoding]::new($false))
  $restoreAttemptId = New-SmokeAttemptId
  Remove-Item -LiteralPath $restoreResultFile -Force -ErrorAction SilentlyContinue
  $restoreResult = Invoke-DetachedUpdateHelper (Get-UpdateHelper $oldDir) $installRoot $taskName $oldTag $newTag `
    $oldVersion $newVersion $restoreResultFile -AttemptId $restoreAttemptId
  Assert-True $restoreResult.success "Could not restore the old release after the rollback CAS test"
  Wait-DalaVersion $port $oldVersion
  Assert-TaskAction $taskName $oldLauncher $runner $logFile

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
  & $installer -Version $newTag -ArchivePath $archive -ChecksumPath $checksum `
    -ExpectedVersion $newVersion -HealthTimeoutSeconds 90
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
  Stop-Process -Id $foreignUpdateErlPid -Force -ErrorAction SilentlyContinue
  $foreignUpdateErlPid = $null

  Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
  Set-SmokeTaskRunner $taskName $newLauncher $smokeRunner $logFile $newBatch $installRoot $port $newVersion

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
  & $uninstall -PurgeData
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
  Write-DalaIdentityFixture $expandedNew $reparseVictimRelease $newVersion
  New-Item -ItemType Junction -Path $reparseJunction -Target $reparseVictim | Out-Null
  $reparseRelease = Join-Path $reparseJunction $newTag
  $reparseErlProcess = Start-BootedErl $reparseRelease $newVersion
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
    successful_update = $true
    holder_pid_preserved = $true
    shell_pid_preserved = $true
    secrets_absent_from_environment = $true
    purge_killed_live_session = $true
    non_purge_preserved_data = $true
    install_metadata_conflict_rejected = $installConflictRejected
    root_discovery_mismatch_rejected = $metadataMismatchRejected
    config_port_synced_to_metadata = $true
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
