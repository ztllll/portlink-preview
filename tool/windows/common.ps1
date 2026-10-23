# Shared implementation for Windows PowerShell 5.1 and PowerShell 7.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Windows {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Requires a real Windows host. Nothing was installed or built.'
    }
}
function Get-ProjectRoot { return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path }
function Get-FullPath([string]$Path) { return [IO.Path]::GetFullPath($Path) }
function Assert-Under([string]$Path, [string]$Parent) {
    $full = Get-FullPath $Path
    $root = (Get-FullPath $Parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside designated directory: $full"
    }
    return $full
}
function Assert-NoLinks([string]$Root) {
    $resolved = Get-Item -LiteralPath $Root
    if (($resolved.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point: $Root" }
    foreach ($entry in Get-ChildItem -LiteralPath $Root -Force -Recurse) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point: $($entry.FullName)" }
    }
}
function Write-Json([object]$Value, [string]$Path) {
    $json = $Value | ConvertTo-Json -Depth 30
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE ($([IO.Path]::GetFileName($Executable)))" }
}
function Resolve-Flutter([string]$FlutterRoot) {
    if (-not $FlutterRoot) { $FlutterRoot = $env:FLUTTER_ROOT }
    if (-not $FlutterRoot) {
        $command = Get-Command flutter.bat -ErrorAction SilentlyContinue
        if ($command) { $FlutterRoot = Split-Path (Split-Path $command.Source -Parent) -Parent }
    }
    if (-not $FlutterRoot) { throw 'Pass -FlutterRoot or set FLUTTER_ROOT to an existing Windows Flutter SDK.' }
    $root = (Resolve-Path -LiteralPath $FlutterRoot).Path
    foreach ($relative in @('bin\flutter.bat', 'bin\cache\dart-sdk\bin\dart.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $relative) -PathType Leaf)) {
            throw "Flutter SDK is not bootstrapped: missing $relative. Prepare it explicitly first."
        }
    }
    $metadataPath = Join-Path $root 'bin\cache\flutter.version.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) { throw 'Missing cached Flutter version metadata.' }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $flutterVersion = [string]$metadata.frameworkVersion
    if ($metadata.PSObject.Properties.Name -contains 'flutterVersion') { $flutterVersion = [string]$metadata.flutterVersion }
    if ($flutterVersion -notmatch '^(\d+)\.(\d+)\.') { throw 'Cannot verify Flutter version.' }
    if ([int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 47)) { throw 'Flutter 3.47+ required.' }
    $dartVersion = [string]$metadata.dartSdkVersion
    if ($dartVersion -notmatch '^(\d+)\.(\d+)\.') { throw 'Cannot verify Dart version.' }
    if ([int]$Matches[1] -lt 3 -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -lt 13)) { throw 'Dart 3.13+ required.' }
    return [pscustomobject]@{ Root = $root; Flutter = (Join-Path $root 'bin\flutter.bat'); Dart = (Join-Path $root 'bin\cache\dart-sdk\bin\dart.exe'); Metadata = $metadata }
}
function Get-WindowsToolchain([string]$Architecture) {
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Installer/vswhere missing. Install Desktop development with C++ yourself; this script never installs tools.' }
    $instances = (& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | Out-String | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { throw 'vswhere failed.' }
    foreach ($instance in @($instances)) {
        $vc = Join-Path $instance.installationPath 'VC\Tools\MSVC'
        if (-not (Test-Path -LiteralPath $vc)) { continue }
        foreach ($toolset in @(Get-ChildItem -LiteralPath $vc -Directory | Sort-Object Name -Descending)) {
            $compiler = Join-Path $toolset.FullName "bin\Hostx64\$Architecture\cl.exe"
            $atlHeader = Join-Path $toolset.FullName 'atlmfc\include\atlstr.h'
            $atlLib = Join-Path $toolset.FullName "atlmfc\lib\$Architecture\atls.lib"
            $cmake = Join-Path $instance.installationPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
            if ((Test-Path -LiteralPath $compiler) -and (Test-Path -LiteralPath $atlHeader) -and
                (Test-Path -LiteralPath $atlLib) -and (Test-Path -LiteralPath $cmake)) {
                $sdkRoot = Join-Path $programFilesX86 'Windows Kits\10\Include'
                $sdks = @()
                if (Test-Path -LiteralPath $sdkRoot) { $sdks = @(Get-ChildItem -LiteralPath $sdkRoot -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\windows.h') }) }
                if ($sdks.Count -eq 0) { throw 'Windows 10/11 SDK headers missing.' }
                $redist = Join-Path $instance.installationPath 'VC\Redist\MSVC'
                $crt = @()
                if (Test-Path -LiteralPath $redist) {
                    $crt = @(Get-ChildItem -LiteralPath $redist -Directory | Sort-Object Name -Descending | ForEach-Object {
                        $archRoot = Join-Path $_.FullName $Architecture
                        if (Test-Path -LiteralPath $archRoot) { Get-ChildItem -LiteralPath $archRoot -Directory | Where-Object { $_.Name -match '^Microsoft\.VC\d+\.CRT$' } }
                    })
                }
                if ($crt.Count -eq 0) { throw "App-local VC redistributable CRT not found for $Architecture. Verify components and redistribution license." }
                return [pscustomobject]@{ InstallationPath = $instance.installationPath; Toolset = $toolset.Name; Compiler = $compiler; AtlHeader = $atlHeader; AtlLibrary = $atlLib; CrtDirectory = $crt[0].FullName; WindowsSdk = ($sdks | Sort-Object Name -Descending | Select-Object -First 1).Name }
            }
        }
    }
    throw "No usable Visual Studio C++/CMake/ATL toolchain for $Architecture. Add C++ ATL for the matching toolset and architecture. No installation attempted."
}
function Test-JniCompatibility([string]$ProjectRoot) {
    $configPath = Join-Path $ProjectRoot '.dart_tool\package_config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { throw 'Run flutter pub get --enforce-lockfile first (or build.ps1 -ResolveDependencies).' }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $entry = @($config.packages | Where-Object { $_.name -eq 'jni' })
    if ($entry.Count -ne 1) { throw 'Expected one pinned jni package in package_config.' }
    $base = New-Object Uri((Get-FullPath $configPath))
    $packageUri = New-Object Uri($base, [string]$entry[0].rootUri)
    $source = Join-Path $packageUri.LocalPath 'src\CMakeLists.txt'
    if (-not (Test-Path -LiteralPath $source)) { throw 'Cannot inspect resolved JNI CMake source.' }
    $native = Get-Content -LiteralPath $source -Raw
    $project = Get-Content -LiteralPath (Join-Path $ProjectRoot 'windows\CMakeLists.txt') -Raw
    if ($native -match 'set_target_properties\(\$\{TARGET_NAME\}' -and
        $project -notmatch '(?s)set\(TARGET_NAME\s+"jni"\)\s*include\(flutter/generated_plugins\.cmake\)\s*unset\(TARGET_NAME\)') {
        throw 'JNI TARGET_NAME compatibility guard is missing or no longer scoped to generated plugins.'
    }
    return [pscustomobject]@{ Source = $source; SourceSha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash; UsesTargetNameWorkaround = ($native -match 'set_target_properties\(\$\{TARGET_NAME\}') }
}
function Invoke-BundleInspection([string]$ProjectRoot, [string]$Dart, [string]$Bundle, [string]$Architecture) {
    $script = Join-Path $ProjectRoot 'tool\windows\verify_bundle.dart'
    $plugins = Join-Path $ProjectRoot 'windows\flutter\generated_plugins.cmake'
    $output = & $Dart $script --bundle $Bundle --arch $Architecture --plugins $plugins
    if ($LASTEXITCODE -ne 0) { throw ('Bundle verification failed: ' + ($output -join [Environment]::NewLine)) }
    return ($output -join [Environment]::NewLine | ConvertFrom-Json)
}
function Get-Inventory([string]$Root) {
    Assert-NoLinks $Root
    $base = (Get-FullPath $Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Where-Object { $_.Name -ne 'portable-manifest.json' } | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{ path = $_.FullName.Substring($base.Length).Replace('\', '/'); length = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
}
function Test-Inventory([string]$Root, [object]$Manifest) {
    if ($Manifest.schemaVersion -ne 1 -or $Manifest.kind -ne 'portlink-windows-portable') { throw 'Unsupported portable manifest.' }
    $actual = @(Get-Inventory $Root); $expected = @($Manifest.files)
    if ($actual.Count -ne $expected.Count) { throw 'ZIP file count mismatch.' }
    $map = @{}
    foreach ($item in $expected) {
        if ($map.ContainsKey([string]$item.path)) { throw 'Duplicate inventory path.' }
        $map[[string]$item.path] = $item
    }
    foreach ($item in $actual) {
        if (-not $map.ContainsKey($item.path)) { throw "Unexpected file: $($item.path)" }
        $match = $map[$item.path]
        if ($match.length -ne $item.length -or $match.sha256 -ne $item.sha256) { throw "File hash/length mismatch: $($item.path)" }
    }
}
