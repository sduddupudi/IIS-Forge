<#
.SYNOPSIS
Example generated launcher. Real launchers are created by scripts\new-iis-forge-profile.ps1.
#>

param(
    [string]$Branch = "",
    [switch]$RunTests,
    [switch]$NoProgress
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$profilePath = Join-Path $PSScriptRoot "profiles\example.com.json"
$enginePath = Join-Path $PSScriptRoot "scripts\iis-forge.ps1"
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json

$arguments = @{
    RepoPath = [string]$profile.RepoPath
    ProjectPath = [string]$profile.ProjectPath
    SolutionPath = [string]$profile.SolutionPath
    StaticPublishPath = [string]$profile.StaticPublishPath
    Remote = [string]$profile.Remote
    Branch = [string]$profile.Branch
    GitHubRepositoryUrl = [string]$profile.GitRepositoryUrl
    SiteName = [string]$profile.SiteName
    IisPath = [string]$profile.IisPath
    AppPoolName = [string]$profile.AppPoolName
    ReleasesRoot = [string]$profile.ReleasesRoot
    Configuration = [string]$profile.Configuration
    RuntimeIdentifier = [string]$profile.RuntimeIdentifier
    SelfContained = [bool]$profile.SelfContained
    KeepReleases = [int]$profile.KeepReleases
    PreserveFiles = @($profile.PreserveFiles)
    InstallMissingDependencies = [bool]$profile.InstallMissingDependencies
}

if (-not [string]::IsNullOrWhiteSpace($Branch)) {
    $arguments.Branch = $Branch
}
if ($RunTests) {
    $arguments.RunTests = $true
}
if ($NoProgress) {
    $arguments.NoProgress = $true
}

& $enginePath @arguments
