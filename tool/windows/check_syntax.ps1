[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$failed = $false
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failed = $true
        foreach ($errorRecord in $errors) { Write-Error ($file.Name + ': ' + $errorRecord.Message) -ErrorAction Continue }
    }
}
if ($failed) { throw 'PowerShell syntax validation failed.' }
Write-Host 'PowerShell parser accepted all Windows scripts; no build or application was started.'
