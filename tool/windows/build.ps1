[CmdletBinding()]
param(
    [string]$FlutterRoot,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [switch]$ResolveDependencies,
    [switch]$RunTests
)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Windows
$project = Get-ProjectRoot
$sdk = Resolve-Flutter $FlutterRoot
$toolchain = Get-WindowsToolchain $Architecture
Push-Location $project
$lock = $null
try {
    [IO.Directory]::CreateDirectory((Join-Path $project 'build')) | Out-Null
    # An exclusive file handle prevents these scripts running overlapping Flutter
    # builds/tests in this checkout. It never kills another process or deletes caches.
    $lock = [IO.File]::Open((Join-Path $project 'build\portlink-windows.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    if (-not (Test-Path -LiteralPath (Join-Path $project 'pubspec.lock'))) { throw 'pubspec.lock is required.' }
    $lockHash = (Get-FileHash -LiteralPath 'pubspec.lock' -Algorithm SHA256).Hash
    if ($ResolveDependencies) {
        Invoke-Checked $sdk.Flutter @('pub', 'get', '--enforce-lockfile')
    }
    if ($lockHash -ne (Get-FileHash -LiteralPath 'pubspec.lock' -Algorithm SHA256).Hash) { throw 'Dependency lockfile changed; inspect it before building.' }
    $jni = Test-JniCompatibility $project
    if ($RunTests) {
        Invoke-Checked $sdk.Flutter @('test', '--no-pub', '--concurrency=1')
    }
    # Explicit normal application entry: never package a smoke-test entry point.
    # Flutter 3.47 selects Windows architecture from the host; it does not
    # expose a working --target-platform override in BuildWindowsCommand.
    $hostArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($hostArchitecture -ne $Architecture) { throw "This Flutter SDK builds the host architecture ($hostArchitecture); requested $Architecture. Use a matching Windows host." }
    Invoke-Checked $sdk.Flutter @('build', 'windows', '--release', '--no-pub', '--target', 'lib/main.dart')
    $release = Join-Path $project "build\windows\$Architecture\runner\Release"
    if (-not (Test-Path -LiteralPath $release -PathType Container)) { throw "Expected Release directory missing: $release" }
    $provenance = [ordered]@{
        schemaVersion = 1; kind = 'portlink-windows-build'; architecture = $Architecture
        entryPoint = 'lib/main.dart'; buildMode = 'release'; builtUtc = [DateTime]::UtcNow.ToString('o')
        flutter = $sdk.Metadata; toolchain = $toolchain; jni = $jni
        pubspecLockSha256 = $lockHash.ToLowerInvariant(); testsRequested = [bool]$RunTests
        exeSha256 = (Get-FileHash -LiteralPath (Join-Path $release 'portlink.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
        releaseFiles = @(Get-Inventory $release -IncludeRootManifest)
        runtimeSmokeTested = $false
    }
    Write-Json $provenance (Join-Path $project "build\windows\$Architecture\portlink-build.json")
    Write-Host "Release compilation completed: $release"
    Write-Host 'Next: package.ps1 copies app-local CRT, verifies every DLL/native asset, creates ZIP and verifies its extraction.'
    Write-Host 'This is not an interactive smoke test or a signed public release.'
} finally {
    if ($lock) { $lock.Dispose() }
    Pop-Location
}
