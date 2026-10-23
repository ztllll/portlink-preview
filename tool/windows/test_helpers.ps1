[CmdletBinding()]
param()
# Portable logic tests only. No Windows toolchain, user credentials or app start.
. (Join-Path $PSScriptRoot 'common.ps1')
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('portlink-script-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
    $sdk = Join-Path $temporary 'sdk'
    foreach ($item in @('bin/flutter.bat', 'bin/cache/dart-sdk/bin/dart.exe')) {
        $target = Join-Path $sdk $item
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        [IO.File]::WriteAllText($target, 'fixture only; never executed')
    }
    $metadata = Join-Path $sdk 'bin/cache/flutter.version.json'
    foreach ($value in @(
        @{ flutterVersion = '3.47.0'; dartSdkVersion = '3.13.0' },
        @{ frameworkVersion = '3.47.0'; dartSdkVersion = '3.13.0' },
        @{ flutterVersion = '3.47.0'; frameworkVersion = 'old'; dartSdkVersion = '3.13.0' }
    )) {
        Write-Json $value $metadata
        $resolved = Resolve-Flutter $sdk
        if (-not $resolved.Root) { throw 'Version metadata variant was rejected.' }
    }
    Write-Json @{ dartSdkVersion = '3.13.0' } $metadata
    $rejected = $false
    try { Resolve-Flutter $sdk | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Missing version must fail closed.' }
    $payload = Join-Path $temporary 'payload'
    [IO.Directory]::CreateDirectory((Join-Path $payload 'data')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $payload 'portable-manifest.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $payload 'data/portable-manifest.json'), 'nested payload')
    $inventory = @(Get-Inventory $payload)
    if ($inventory.Count -ne 1 -or $inventory[0].path -ne 'data/portable-manifest.json') { throw 'Only root manifest may be excluded.' }
    $manifest = [pscustomobject]@{ schemaVersion = 1; kind = 'portlink-windows-portable'; files = $inventory }
    Test-Inventory $payload $manifest
    [IO.File]::AppendAllText((Join-Path $payload 'data/portable-manifest.json'), 'tampered')
    $rejected = $false
    try { Test-Inventory $payload $manifest } catch { $rejected = $true }
    if (-not $rejected) { throw 'Nested manifest tampering was not detected.' }
    $unicodePath = Join-Path $payload 'data/说明.txt'
    [IO.File]::WriteAllText($unicodePath, '中文测试', (New-Object Text.UTF8Encoding($false)))
    $utfManifestPath = Join-Path $temporary 'utf8-manifest.json'
    Write-Json ([pscustomobject]@{schemaVersion=1;kind='portlink-windows-portable';files=@(Get-Inventory $payload)}) $utfManifestPath
    $utfManifest = Get-Content -LiteralPath $utfManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Inventory $payload $utfManifest
    $runtime = Join-Path $temporary 'runtime'
    [IO.Directory]::CreateDirectory((Join-Path $runtime 'data')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $runtime 'portlink.exe'), 'unchanged runner')
    foreach ($name in @('data/app.so', 'native.dll', 'asset.bin')) {
        $file = Join-Path $runtime $name
        [IO.File]::WriteAllText($file, 'original payload')
    }
    $buildInventory = [pscustomobject]@{releaseFiles=@(Get-Inventory $runtime -IncludeRootManifest)}
    Test-BuildInventory $runtime $buildInventory
    foreach ($name in @('data/app.so', 'native.dll', 'asset.bin')) {
        $file = Join-Path $runtime $name
        [IO.File]::WriteAllText($file, 'different payload')
        $rejected = $false
        try { Test-BuildInventory $runtime $buildInventory } catch { $rejected = $true }
        if (-not $rejected) { throw 'AOT/native/asset changes must invalidate successful build provenance.' }
        [IO.File]::WriteAllText($file, 'original payload')
    }
    $release = Join-Path $temporary 'Release'
    [IO.Directory]::CreateDirectory($release) | Out-Null
    foreach ($output in @($release, (Join-Path $release 'new-child'))) {
        $rejected = $false
        try { Assert-OutputOutsideSource $output $release } catch { $rejected = $true }
        if (-not $rejected) { throw 'Output inside Release must be refused before creating files.' }
    }
    if (Test-Path (Join-Path $release 'new-child')) { throw 'Safety check must not create output.' }
    Assert-OutputOutsideSource (Join-Path $temporary 'dist') $release
    $originalLocation = Get-Location
    $originalDirectory = [Environment]::CurrentDirectory
    try {
        Set-Location -LiteralPath $temporary
        [Environment]::CurrentDirectory = [IO.Path]::GetTempPath()
        $relative = Get-FullPath './relative-output'
        if ($relative -ne (Join-Path $temporary 'relative-output')) { throw 'Relative paths must use PowerShell location.' }
    } finally { Set-Location -LiteralPath $originalLocation.Path; [Environment]::CurrentDirectory = $originalDirectory }
    Write-Host 'Helper tests passed: version shapes, root-only manifest exclusion, tamper detection, output recursion refusal.'
} finally {
    # Exact freshly created test-only temporary child; never a caller-supplied path.
    $safe = Assert-Under $temporary ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $safe -Recurse -Force
}
