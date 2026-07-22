[CmdletBinding()]
param([string]$Version)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$RepoPattern = '^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?$'
$DefaultRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Dala"
$DefaultConfigDir = if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
  $null
} else {
  Join-Path $env:APPDATA "Dala"
}
$DefaultDiscoveryFile = if ($DefaultConfigDir) { Join-Path $DefaultConfigDir "install.json" } else { $null }
$DiscoveryFile = if (-not [string]::IsNullOrWhiteSpace($env:DALA_DISCOVERY_FILE)) {
  $env:DALA_DISCOVERY_FILE
} else {
  $DefaultDiscoveryFile
}
$installer = Join-Path ([IO.Path]::GetTempPath()) ("dala-install-" + [guid]::NewGuid().ToString("N") + ".ps1")

function Assert-UpdateRepo([string]$Repo) {
  if ([string]::IsNullOrWhiteSpace($Repo) -or
      $Repo -cnotmatch $RepoPattern) {
    throw "Invalid Dala update repository: $Repo"
  }
  $Repo
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Get-MetadataField($Metadata, [string]$Name) {
  if ($null -eq $Metadata) {
    return [pscustomobject]@{ Present = $false; Value = $null }
  }
  $property = $Metadata.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return [pscustomobject]@{ Present = $false; Value = $null }
  }
  if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
    throw "Dala install metadata field '$Name' is empty"
  }
  [pscustomobject]@{ Present = $true; Value = [string]$property.Value }
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

function Get-CanonicalDiscoveryFile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or
      $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\)' -or
      $Path -match '^\\\\[.?]\\' -or
      ($Path.Length -gt 2 -and $Path.Substring(2).Contains(":"))) {
    throw "Dala discoveryFile must be an absolute Windows path: $Path"
  }
  try {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]"\\/")
  } catch {
    throw "Dala discoveryFile is invalid: $Path"
  }
  if (-not (Test-NoReparseAncestors $full)) {
    throw "Refusing to use Dala discoveryFile through a reparse point: $full"
  }
  if (Test-Path -LiteralPath $full) {
    $attributes = [IO.File]::GetAttributes($full)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        -not (Test-Path -LiteralPath $full -PathType Leaf)) {
      throw "Dala discoveryFile must be a regular file: $full"
    }
  }
  $full
}

function Resolve-DiscoveryMetadata(
  $RootMetadata,
  $BootstrapMetadata,
  [string]$RootMetadataPath,
  [string]$BootstrapPath
) {
  $rootField = Get-MetadataField $RootMetadata "discoveryFile"
  $bootstrapField = Get-MetadataField $BootstrapMetadata "discoveryFile"
  $candidate = if ($rootField.Present) { [string]$rootField.Value } else { $BootstrapPath }
  $path = Get-CanonicalDiscoveryFile $candidate
  $metadata = if ($BootstrapMetadata -and (Test-SamePath $path $BootstrapPath)) {
    $BootstrapMetadata
  } else {
    Read-InstallMetadata $path
  }
  if ($RootMetadata -and $metadata) {
    Assert-InstallMetadataMatch $metadata $RootMetadata
  }
  if (-not $RootMetadata -and $metadata) {
    $metadataField = Get-MetadataField $metadata "discoveryFile"
    if ($metadataField.Present -and
        -not (Test-SamePath (Get-CanonicalDiscoveryFile ([string]$metadataField.Value)) $path)) {
      throw "Dala discovery metadata disagrees with its path"
    }
  }
  [pscustomobject]@{ Path = $path; Metadata = $metadata }
}

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

  $leftField = Get-MetadataField $Left "discoveryFile"
  $rightField = Get-MetadataField $Right "discoveryFile"
  if ($leftField.Present -ne $rightField.Present) {
    throw "Dala discovery and root install metadata disagree on discoveryFile"
  }
  if ($leftField.Present) {
    $leftPath = Get-CanonicalDiscoveryFile ([string]$leftField.Value)
    $rightPath = Get-CanonicalDiscoveryFile ([string]$rightField.Value)
    if (-not (Test-SamePath $leftPath $rightPath)) {
      throw "Dala discovery and root install metadata disagree on discoveryFile"
    }
  }
}

function Get-UpdateRepo {
  $defaultRootMetadataPath = Join-Path ([IO.Path]::GetFullPath($DefaultRoot)) "install.json"
  $defaultRootMetadata = if ($env:DALA_HOME) { $null } else { Read-InstallMetadata $defaultRootMetadataPath }
  $bootstrapPath = $null
  $bootstrapMetadata = $null
  $rootHint = if ($env:DALA_HOME) {
    $env:DALA_HOME
  } elseif ($defaultRootMetadata) {
    $DefaultRoot
  } else {
    $bootstrapPath = Get-CanonicalDiscoveryFile $DiscoveryFile
    $bootstrapMetadata = Read-InstallMetadata $bootstrapPath
    if ($bootstrapMetadata) { [string]$bootstrapMetadata.root } else { $DefaultRoot }
  }
  $rootMetadataPath = Join-Path ([IO.Path]::GetFullPath($rootHint)) "install.json"
  $rootMetadata = if ($defaultRootMetadata -and (Test-SamePath $rootMetadataPath $defaultRootMetadataPath)) {
    $defaultRootMetadata
  } else {
    Read-InstallMetadata $rootMetadataPath
  }
  $rootField = Get-MetadataField $rootMetadata "discoveryFile"
  if (-not $rootField.Present) {
    $bootstrapPath = if ($bootstrapPath) { $bootstrapPath } else { Get-CanonicalDiscoveryFile $DiscoveryFile }
    $bootstrapMetadata = if ($bootstrapMetadata) { $bootstrapMetadata } else { Read-InstallMetadata $bootstrapPath }
  }
  $resolution = Resolve-DiscoveryMetadata $rootMetadata $bootstrapMetadata $rootMetadataPath $bootstrapPath
  $metadata = if ($rootMetadata) { $rootMetadata } else { $resolution.Metadata }

  if (-not $metadata) {
    if ($env:DALA_REPO) { return $env:DALA_REPO }
    return "mjason/dala"
  }
  if ($env:DALA_REPO -and [string]$env:DALA_REPO -cne [string]$metadata.repo) {
    throw "DALA_REPO conflicts with the existing install metadata"
  }
  [string]$metadata.repo
}

try {
  $repo = Assert-UpdateRepo (Get-UpdateRepo)
  Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repo/main/install.ps1" -OutFile $installer

  if ($Version) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Version $Version
  } else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
  }

  $status = $LASTEXITCODE
  if ($status -ne 0) { throw "Dala installer failed with exit status $status" }
} finally {
  Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
}

return
