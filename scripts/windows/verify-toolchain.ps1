[CmdletBinding()]
param(
  [switch]$RustOnly
)

$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$versions = Get-Content -LiteralPath (Join-Path $projectRoot "toolchain.json") -Raw | ConvertFrom-Json

function Assert-Version([string]$Name, [string]$Actual, [string]$Expected) {
  if ($Actual -ne $Expected) {
    throw "$Name version mismatch: expected $Expected, got $Actual"
  }
  Write-Output "$Name $Actual"
}

if (-not $RustOnly) {
  $erl = Get-Command erl.exe -ErrorAction Stop
  $erlangRoot = Split-Path (Split-Path $erl.Source -Parent) -Parent
  $otpVersionFile = Get-ChildItem -Path (Join-Path $erlangRoot "releases\*\OTP_VERSION") -File |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $otpVersionFile) {
    throw "Cannot determine the exact OTP version below $erlangRoot\releases"
  }
  $otpVersion = (Get-Content -LiteralPath $otpVersionFile -Raw).Trim()
  Assert-Version "OTP" $otpVersion ([string]$versions.otp)

  $elixirOutput = (& elixir.bat --version 2>&1 | Out-String)
  if ($elixirOutput -notmatch 'Elixir ([0-9]+(?:\.[0-9]+)+)') {
    throw "Cannot determine Elixir version from: $elixirOutput"
  }
  Assert-Version "Elixir" $Matches[1] ([string]$versions.elixir)

  $nodeVersion = (& node.exe --version 2>&1 | Out-String).Trim().TrimStart('v')
  Assert-Version "Node" $nodeVersion ([string]$versions.node)
}

$rustOutput = (& rustc.exe --version 2>&1 | Out-String)
if ($rustOutput -notmatch '^rustc ([0-9]+(?:\.[0-9]+)+)') {
  throw "Cannot determine Rust version from: $rustOutput"
}
Assert-Version "Rust" $Matches[1] ([string]$versions.rust)

$compiler = Get-Command cl.exe -ErrorAction SilentlyContinue
if ($null -eq $compiler) {
  throw "MSVC cl.exe is not available. Run activate-toolchain.ps1 from PowerShell."
}
Write-Output "MSVC $($compiler.Source)"
