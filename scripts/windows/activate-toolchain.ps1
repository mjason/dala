[CmdletBinding()]
param(
  [string]$ToolRoot = $(
    if ($env:DALA_TOOLCHAIN_ROOT) { $env:DALA_TOOLCHAIN_ROOT }
    else { Join-Path $env:USERPROFILE "tools" }
  ),
  [switch]$UseCurrentTools,
  [switch]$ExportGithubEnv,
  [switch]$RustOnly
)

$ErrorActionPreference = "Stop"
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$versions = Get-Content -LiteralPath (Join-Path $projectRoot "toolchain.json") -Raw | ConvertFrom-Json

if (-not $UseCurrentTools) {
  $cargoBin = Join-Path $env:USERPROFILE ".cargo\bin"
  $toolPaths = @($cargoBin)
  $required = @((Join-Path $cargoBin "rustc.exe"))

  if (-not $RustOnly) {
    $erlangBin = Join-Path $ToolRoot "erlang-$($versions.otp)\bin"
    $elixirBin = Join-Path $ToolRoot "elixir-$($versions.elixir)\bin"
    $nodeRoot = Join-Path $ToolRoot "node-v$($versions.node)-win-x64"
    $toolPaths = @($erlangBin, $elixirBin, $nodeRoot, $cargoBin)
    $required = @(
      (Join-Path $erlangBin "erl.exe"),
      (Join-Path $elixirBin "elixir.bat"),
      (Join-Path $nodeRoot "node.exe"),
      (Join-Path $cargoBin "rustc.exe")
    )
  }

  foreach ($executable in $required) {
    if (-not (Test-Path -LiteralPath $executable)) {
      throw "Required toolchain executable is missing: $executable"
    }
  }

  $env:PATH = ($toolPaths + ($env:PATH -split ';')) -join ';'
}

if (-not $RustOnly) {
  $erl = Get-Command erl.exe -ErrorAction Stop
  $env:ERLANG_HOME = Split-Path (Split-Path $erl.Source -Parent) -Parent
}
$env:RUSTUP_TOOLCHAIN = [string]$versions.rust

if ($null -eq (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Build Tools were not found: $vswhere"
  }

  $vsInstall = (& $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath | Select-Object -First 1)
  if (-not $vsInstall) {
    throw "Visual Studio C++ x64 build tools are not installed"
  }

  $devShellModule = Join-Path $vsInstall "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
  Import-Module $devShellModule
  Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation `
    -DevCmdArguments "-arch=x64 -host_arch=x64" | Out-Null
}

& (Join-Path $PSScriptRoot "verify-toolchain.ps1") -RustOnly:$RustOnly

if ($ExportGithubEnv) {
  if (-not $env:GITHUB_ENV) { throw "GITHUB_ENV is not set" }

  $encoding = [System.Text.UTF8Encoding]::new($false)
  $exportNames = @("PATH", "INCLUDE", "LIB", "LIBPATH", "RUSTUP_TOOLCHAIN")
  if (-not $RustOnly) { $exportNames += "ERLANG_HOME" }

  foreach ($name in $exportNames) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if ($null -ne $value) {
      [System.IO.File]::AppendAllText($env:GITHUB_ENV, "$name=$value`n", $encoding)
    }
  }
}
