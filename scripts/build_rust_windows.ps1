<#!
.SYNOPSIS
  Build the Rust native library (isscore) for Windows and copy the DLL where Flutter can load it.

.DESCRIPTION
  - Builds rust/isscore with cargo (Debug or Release)
  - Ensures crate-type cdylib is present
  - Copies resulting iscore.dll into build/windows/x64/runner/<Config>/ (Flutter runner dir)
  - Optionally launches `flutter run -d windows`
  - Adds simple timing + error handling + colored output

.PARAMETER Configuration
  Build configuration: Release (default) or Debug.

.PARAMETER CopyToRunner
  Copy the DLL to the Flutter runner folder (default: $true)

.PARAMETER FlutterRun
  After build, run the Flutter desktop app (`flutter run -d windows`).

.PARAMETER Clean
  Run `cargo clean` before building.

.PARAMETER VerboseRust
  Pass --verbose to cargo build.

.EXAMPLE
  ./scripts/build_rust_windows.ps1

.EXAMPLE
  ./scripts/build_rust_windows.ps1 -Configuration Debug -FlutterRun

.NOTES
  Run from anywhere; script resolves project root from its own location.
!#>
[CmdletBinding()] Param(
    [ValidateSet('Release','Debug')]
    [string]$Configuration = 'Debug',
    [bool]$CopyToRunner = $true,
    [switch]$FlutterRun,
    [switch]$Clean,
    [switch]$VerboseRust
)

$ErrorActionPreference = 'Stop'
$scriptStart = Get-Date
function Write-Info($m){ Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-Err ($m){ Write-Host "[ERROR] $m" -ForegroundColor Red }
function Write-Step($m){ Write-Host "`n== $m ==" -ForegroundColor Green }

# Resolve paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir  # scripts/ -> root
$cratePath = Join-Path $projectRoot 'rust/isscore'
$cargoToml = Join-Path $cratePath 'Cargo.toml'

if(-not (Test-Path $cargoToml)) { Write-Err "Cargo.toml not found at $cargoToml"; exit 1 }

Write-Step "Project Root"
Write-Info "projectRoot = $projectRoot"
Write-Info "cratePath    = $cratePath"
Write-Info "configuration= $Configuration"

# Quick check crate-type
$cargoTomlContent = Get-Content $cargoToml -Raw
if($cargoTomlContent -notmatch 'crate-type\s*=.*cdylib') {
    Write-Warn "Cargo.toml missing crate-type = ['cdylib']; attempting to append."
    Add-Content -Path $cargoToml -Value "`n[lib]`ncrate-type = [\"cdylib\"]" -Encoding UTF8
    Write-Info "Added [lib] crate-type section."
}

# Optional clean
if($Clean){
    Write-Step "Cleaning"
    Push-Location $cratePath
    cargo clean
    Pop-Location
}

# Build
Write-Step "Building Rust library"
Push-Location $cratePath
$cargoArgs = @('build','--config','build.rustflags="-C strip=none"','--profile',$Configuration.ToLower())
if($Configuration -eq 'Release'){ $cargoArgs = @('build','--release') } else { $cargoArgs = @('build') }
if($VerboseRust){ $cargoArgs += '--verbose' }
Write-Info "Running: cargo $($cargoArgs -join ' ')"

# Run cargo without capturing to variable (avoids NativeCommandError for normal stderr usage)
& cargo @cargoArgs #--features wgs72
$exit = $LASTEXITCODE
Pop-Location
if($exit -ne 0){ Write-Err "Cargo build failed (exit code $exit)"; exit $exit }
Write-Info "Cargo build succeeded (exit code 0)"

# Determine built DLL path
$targetDir = if($Configuration -eq 'Release'){ 'release' } else { 'debug' }
$dllSource = Join-Path $cratePath "target/$targetDir/isscore.dll"
if(-not (Test-Path $dllSource)) { Write-Err "Built DLL not found at $dllSource"; exit 1 }
Write-Info "Built DLL: $dllSource"

if($CopyToRunner){
    Write-Step "Copying DLL to Flutter runner"
    $runnerDir = Join-Path $projectRoot "build/windows/x64/runner/$Configuration"
    if(-not (Test-Path $runnerDir)) { New-Item -ItemType Directory -Force -Path $runnerDir | Out-Null }
    $dest = Join-Path $runnerDir 'isscore.dll'
    Copy-Item $dllSource $dest -Force
    Write-Info "Copied to $dest"
}

$elapsed = (Get-Date) - $scriptStart
Write-Step "Summary"
Write-Info "Elapsed: {0:n1}s" -f $elapsed.TotalSeconds
Write-Info "Configuration: $Configuration"
Write-Info "DLL path: $dllSource"

if($FlutterRun){
    Write-Step "Launching Flutter Windows app"
    Push-Location $projectRoot
    $env:PATH = (Split-Path $dllSource) + ';' + $env:PATH
    flutter run -d windows
    Pop-Location
}
