[CmdletBinding()]
param(
  [string]$Version,
  [string]$Repository = "mjason/dala",
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "Dala"),
  [int]$Port = 4400,
  [int]$HealthCheckAttempts = 30,
  [switch]$NoStart
)

$ErrorActionPreference = "Stop"

# GitHub requires TLS 1.2; older Windows PowerShell/.NET defaults may not.
[Net.ServicePointManager]::SecurityProtocol =
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Assert-ValidRepository([string]$Name) {
  if ($Name -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Invalid GitHub repository: $Name"
  }
}

function Assert-ValidVersion([string]$Tag) {
  if ($Tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid release version: $Tag"
  }
}

function Invoke-GitHubJson([string]$Uri) {
  $headers = @{ "User-Agent" = "dala-windows-installer"; "Accept" = "application/vnd.github+json" }
  try {
    return Invoke-RestMethod -Uri $Uri -Headers $headers
  } catch {
    throw "Could not query GitHub Releases at ${Uri}: $($_.Exception.Message)"
  }
}

function Get-LatestServerVersion([string]$Repo) {
  $releases = @(Invoke-GitHubJson "https://api.github.com/repos/$Repo/releases?per_page=100")
  $release = $releases |
    Where-Object {
      $assetNames = @($_.assets | ForEach-Object { $_.name })
      -not $_.draft -and
        -not $_.prerelease -and
        $_.tag_name -match '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$' -and
        $assetNames -contains "dala-$($_.tag_name)-windows-x86_64.zip" -and
        $assetNames -contains "dala-$($_.tag_name)-windows-x86_64.zip.sha256"
    } |
    Select-Object -First 1

  if ($null -eq $release) {
    throw "No stable Dala server release with Windows assets was found in https://github.com/$Repo/releases"
  }

  return [string]$release.tag_name
}

function Assert-WindowsAssets([string]$Repo, [string]$Tag) {
  $release = Invoke-GitHubJson "https://api.github.com/repos/$Repo/releases/tags/$Tag"
  $assetNames = @($release.assets | ForEach-Object { $_.name })
  $assetName = "dala-$Tag-windows-x86_64.zip"
  if ($assetNames -notcontains $assetName -or
      $assetNames -notcontains "$assetName.sha256") {
    throw "Release $Tag does not contain both $assetName and $assetName.sha256"
  }
}

function Download-File([string]$Uri, [string]$Path) {
  try {
    Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing
  } catch {
    throw "Could not download ${Uri}: $($_.Exception.Message)"
  }

  if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
    throw "Downloaded file is empty: $Uri"
  }
}

function Get-ExpectedHash([string]$ChecksumPath, [string]$AssetName) {
  $contents = Get-Content -LiteralPath $ChecksumPath -Raw
  $match = [regex]::Match($contents, '(?im)^\s*([0-9a-f]{64})\s+\*?' + [regex]::Escape($AssetName) + '\s*$')
  if (-not $match.Success) {
    throw "Checksum file does not contain a SHA-256 entry for $AssetName"
  }

  return $match.Groups[1].Value.ToLowerInvariant()
}

Assert-ValidRepository $Repository
if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535" }
if ($HealthCheckAttempts -lt 1) { throw "HealthCheckAttempts must be positive" }

if (-not $Version) {
  $Version = Get-LatestServerVersion $Repository
}
Assert-ValidVersion $Version
Assert-WindowsAssets $Repository $Version

$assetName = "dala-$Version-windows-x86_64.zip"
$baseUrl = "https://github.com/$Repository/releases/download/$Version"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dala-install-" + [guid]::NewGuid().ToString("N"))
$archivePath = Join-Path $tempRoot $assetName
$checksumPath = "$archivePath.sha256"
$extractRoot = Join-Path $tempRoot "release"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot, $extractRoot | Out-Null
  Write-Output "Downloading Dala $Version for Windows x86_64..."
  Download-File "$baseUrl/$assetName" $archivePath
  Download-File "$baseUrl/$assetName.sha256" $checksumPath

  $expectedHash = Get-ExpectedHash $checksumPath $assetName
  $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash) {
    throw "SHA-256 verification failed for $assetName"
  }

  Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
  $installer = Join-Path $extractRoot "scripts\windows\install-service.ps1"
  if (-not (Test-Path -LiteralPath $installer)) {
    throw "The release does not contain scripts\windows\install-service.ps1"
  }

  $installerArgs = @{
    SourceRoot = $extractRoot
    InstallRoot = $InstallRoot
    Version = $Version
    Port = $Port
    HealthCheckAttempts = $HealthCheckAttempts
  }
  if ($NoStart) { $installerArgs.NoStart = $true }

  & $installer @installerArgs
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
