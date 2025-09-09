param(
    [string]$CratePath = ".\rust\isscore",
    [string]$OutDir = ".\android\app\src\main\jniLibs"
)

$ErrorActionPreference = "Stop"

$ndk = (Get-Command cargo-ndk -ErrorAction SilentlyContinue)
if (-not $ndk) {
    Write-Host "cargo-ndk not found. Install with: cargo install cargo-ndk" -ForegroundColor Yellow
    exit 1
}

$abis = @(
    "aarch64-linux-android",
    "armv7-linux-androideabi",
    "x86_64-linux-android"
)

foreach ($abi in $abis) {
    Write-Host "Building for $abi..." -ForegroundColor Cyan
    pushd $CratePath
    cargo ndk -t $abi -o "$PWD\..\..\android\app\src\main\jniLibs" build --release
    popd
}

Write-Host "Done. Native libs copied under android/app/src/main/jniLibs/<abi>/libisscore.so" -ForegroundColor Green
