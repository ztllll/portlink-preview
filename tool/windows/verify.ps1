[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [string]$FlutterRoot,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64'
)
. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Windows
$project = Get-ProjectRoot
$sdk = Resolve-Flutter $FlutterRoot
$zip = (Resolve-Path -LiteralPath $ZipPath).Path
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
$extract = Join-Path ([IO.Path]::GetTempPath()) ('portlink-verify-' + [Guid]::NewGuid().ToString('N'))
# Newly generated child of the actual temp directory; never delete a caller path.
$extract = Assert-Under $extract ([IO.Path]::GetTempPath())
[IO.Directory]::CreateDirectory($extract) | Out-Null
$passed = $false
try {
    $seen = @{}; [long]$expanded = 0
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        if (-not $name -or $name.StartsWith('/') -or $name.Contains(':') -or
            $name -match '(^|/)\.\.?(?:/|$)' -or $name -match '[\x00-\x1f]' -or
            $name -match '(^|/)[^/]*[. ](/|$)' -or $name -match '(^|/)(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|/|$)') {
            throw 'Unsafe ZIP entry path.'
        }
        if ($seen.ContainsKey($name)) { throw 'Duplicate case-insensitive ZIP entry.' }
        $seen[$name] = $true
        $mode = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($mode -eq 0xA000) { throw 'ZIP symbolic link not allowed.' }
        $expanded += $entry.Length
        if ($expanded -gt 2147483648 -or $archive.Entries.Count -gt 100000) { throw 'ZIP extraction limit exceeded.' }
        $target = Assert-Under (Join-Path $extract $name) $extract
        if ($name.EndsWith('/')) { [IO.Directory]::CreateDirectory($target) | Out-Null; continue }
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        $input = $entry.Open()
        $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
    $manifestPath = Join-Path $extract 'portable-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Portable manifest missing from ZIP root.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.architecture -ne $Architecture) { throw 'ZIP architecture mismatch.' }
    Test-Inventory $extract $manifest
    $inspection = Invoke-BundleInspection $project $sdk.Dart $extract $Architecture
    $report = [ordered]@{
        schemaVersion = 1; kind = 'portlink-windows-zip-verification'; valid = $true
        zipSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        fileCount = @($manifest.files).Count; architecture = $Architecture
        checkedUtc = [DateTime]::UtcNow.ToString('o'); structure = $inspection
        runtimeSmokeTested = $false; authenticodeVerified = $false
    }
    Write-Json $report ($zip + '.verification.json')
    [IO.File]::WriteAllText(($zip + '.sha256'), ($report.zipSha256 + '  ' + [IO.Path]::GetFileName($zip) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    $passed = $true
    Write-Host 'ZIP extracted to a fresh directory; every inventoried file hash and runtime dependency verified.'
    Write-Host 'This does not start PortLink and is not a live Windows acceptance test.'
} finally {
    $archive.Dispose()
    if ($passed) {
        # Resolve the exact fresh temp child again before deletion.
        $verifiedTemp = Assert-Under $extract ([IO.Path]::GetTempPath())
        Remove-Item -LiteralPath $verifiedTemp -Recurse -Force
    } else {
        Write-Warning "Verification failed; temporary evidence retained at $extract"
    }
}
