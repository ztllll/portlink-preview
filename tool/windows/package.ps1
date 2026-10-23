[CmdletBinding()]
param(
    [string]$FlutterRoot,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$OutputDirectory
)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Windows
$project = Get-ProjectRoot
$sdk = Resolve-Flutter $FlutterRoot
$toolchain = Get-WindowsToolchain $Architecture
$packageLock = $null
try {
[IO.Directory]::CreateDirectory((Join-Path $project 'build')) | Out-Null
$packageLock = [IO.File]::Open((Join-Path $project 'build\portlink-windows.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $project 'dist\windows' }
$output = Get-FullPath $OutputDirectory
$release = Join-Path $project "build\windows\$Architecture\runner\Release"
$buildReport = Join-Path $project "build\windows\$Architecture\portlink-build.json"
if (-not (Test-Path -LiteralPath $buildReport)) { throw 'No build provenance. Run build.ps1 for the normal entry point first.' }
$provenance = Get-Content -LiteralPath $buildReport -Raw | ConvertFrom-Json
if ($provenance.entryPoint -ne 'lib/main.dart' -or $provenance.architecture -ne $Architecture -or $provenance.buildMode -ne 'release') { throw 'Build provenance mismatch.' }
if ($provenance.exeSha256 -ne (Get-FileHash -LiteralPath (Join-Path $release 'portlink.exe') -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Executable changed since build report.' }
Assert-NoLinks $release
[IO.Directory]::CreateDirectory($output) | Out-Null
$identifier = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$name = "PortLink-windows-$Architecture-$identifier"
$stage = Assert-Under (Join-Path $output $name) $output
$zip = Assert-Under (Join-Path $output ($name + '.zip')) $output
if ((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $zip)) { throw 'Refusing to overwrite an existing artifact.' }
[IO.Directory]::CreateDirectory($stage) | Out-Null
# Copy the entire Release tree; never distribute only portlink.exe.
foreach ($entry in Get-ChildItem -LiteralPath $release -Force) {
    Copy-Item -LiteralPath $entry.FullName -Destination $stage -Recurse -Force
}
# Release CRT redistribution only from installed Visual Studio redistributable
# directory. No System32 scraping, runtime installer, or license bypass.
$crtFiles = @(Get-ChildItem -LiteralPath $toolchain.CrtDirectory -Filter '*.dll' -File)
if ($crtFiles.Count -eq 0) { throw 'No app-local release CRT DLLs found.' }
foreach ($dll in $crtFiles) { Copy-Item -LiteralPath $dll.FullName -Destination $stage -Force }
$inspection = Invoke-BundleInspection $project $sdk.Dart $stage $Architecture
Copy-Item -LiteralPath $buildReport -Destination (Join-Path $stage 'build-provenance.json')
[IO.File]::WriteAllText((Join-Path $stage 'PORTABLE-NOTICE.txt'), @'
PortLink Windows portable preview
Extract the entire ZIP to a writable folder before opening portlink.exe.
Do not copy only the EXE. The data directory, plugin DLLs, native assets, and
app-local Microsoft VC runtime DLLs must remain together. VC files are subject
to the Microsoft Visual Studio redistribution license.
This package is not automatically code signed or installed. Do not disable
SmartScreen, antivirus, execution policy, or firewall to run it. Use a trusted
signature/distribution channel for a public release.
Passwords remain in Windows OS-protected storage; this ZIP does not export
saved credentials or configuration. Configure servers in the application UI.
Production forwarding is fixed 127.0.0.1:3080. If occupied, stop only your own
known forwarding session or choose not to connect; PortLink never kills it.
'@, (New-Object Text.UTF8Encoding($false)))
$manifest = [ordered]@{
    schemaVersion = 1; kind = 'portlink-windows-portable'; architecture = $Architecture
    createdUtc = [DateTime]::UtcNow.ToString('o'); runtimeSmokeTested = $false
    authenticodeVerified = $false; structure = $inspection
    files = @(Get-Inventory $stage)
}
Write-Json $manifest (Join-Path $stage 'portable-manifest.json')
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)
& (Join-Path $PSScriptRoot 'verify.ps1') -FlutterRoot $sdk.Root -Architecture $Architecture -ZipPath $zip
if (-not $?) { throw 'ZIP extraction verification failed.' }
Write-Host "Verified portable ZIP: $zip"
Write-Host 'No process was started. Complete the interactive Windows acceptance checklist before calling this runtime-verified.'
} finally {
    if ($packageLock) { $packageLock.Dispose() }
}
