<#
.SYNOPSIS
Validates IIS Forge PowerShell scripts.
#>

param(
    [string]$RootPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    if ((Split-Path -Leaf $PSScriptRoot) -ieq "scripts") {
        $RootPath = Split-Path -Parent $PSScriptRoot
    }
    elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot "iis-forge.ps1") -PathType Leaf) {
        $RootPath = $PSScriptRoot
    }
    else {
        $RootPath = Split-Path -Parent $PSScriptRoot
    }
}

$scripts = @(
    Join-Path $RootPath "iis-forge.ps1"
    Join-Path $RootPath "new-iis-forge-profile.ps1"
    Join-Path $RootPath "Test-IISForge.ps1"
    Join-Path $RootPath "scripts\iis-forge.ps1"
    Join-Path $RootPath "scripts\new-iis-forge-profile.ps1"
    Join-Path $RootPath "scripts\Test-IISForge.ps1"
)

foreach ($script in $scripts) {
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "Script not found: $script"
    }

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        Write-Host "Parser errors in $script" -ForegroundColor Red
        $errors | Format-List *
        throw "PowerShell parser validation failed."
    }

    Write-Host "Parser OK: $script"
}

$hardcodedPathPattern = '(?<![A-Za-z])[A-Za-z]:[\\/]'
$scannedFiles = Get-ChildItem -LiteralPath $RootPath -Recurse -File |
    Where-Object {
        $_.FullName -notmatch "\\\.git\\" -and
        $_.Extension -in @(".ps1", ".psm1", ".json", ".md")
    }

$hardcodedPathMatches = @()
foreach ($file in $scannedFiles) {
    $matches = Select-String -LiteralPath $file.FullName -Pattern $hardcodedPathPattern -AllMatches
    if ($matches) {
        $hardcodedPathMatches += $matches
    }
}

if ($hardcodedPathMatches.Count -gt 0) {
    Write-Host "Drive-rooted paths found:" -ForegroundColor Red
    $hardcodedPathMatches | ForEach-Object {
        Write-Host ("{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim()) -ForegroundColor Red
    }
    throw "Hardcoded drive-rooted path validation failed."
}

Write-Host "Hardcoded drive-rooted path scan OK."
Write-Host "IIS Forge validation complete."
