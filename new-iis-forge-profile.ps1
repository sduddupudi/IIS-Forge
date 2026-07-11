<#
.SYNOPSIS
Creates an IIS Forge deployment profile and a site-specific launcher script.

.DESCRIPTION
Run this once per IIS site/application. The wizard saves a JSON profile under
profiles\ and generates a small launcher named <profile>.deploy.ps1.

All generated launchers call the shared scripts\iis-forge.ps1 engine, so many IIS
sites can be deployed with one engine file and separate profiles.

By default, every generated file and working folder stays inside the IIS Forge
install folder. Profiles use relative defaults so they can move with that folder.

.EXAMPLE
.\scripts\new-iis-forge-profile.ps1

.EXAMPLE
.\scripts\new-iis-forge-profile.ps1 -ProfileName api.example.com -Configure
#>

param(
    [string]$ProfileName = "",
    [string]$InstallRoot = "",
    [switch]$Configure
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Read-IisForgeValue {
    param(
        [string]$Prompt,
        [string]$DefaultValue = "",
        [switch]$AllowEmpty
    )

    while ($true) {
        if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
            $message = $Prompt
        }
        else {
            $message = "$Prompt [$DefaultValue]"
        }

        $value = Read-Host $message
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = $DefaultValue
        }

        if ($AllowEmpty -or -not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }

        Write-Host "Value required."
    }
}

function ConvertTo-IisForgeSlug {
    param([string]$Value)

    $slug = $Value.Trim().ToLowerInvariant()
    $slug = $slug -replace "^https?://", ""
    $slug = $slug -replace "\.git$", ""
    $slug = $slug -replace "[^a-z0-9.-]+", "-"
    $slug = $slug.Trim(".-")

    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw "Could not create a profile name from '$Value'."
    }

    return $slug
}

function Split-PreserveFiles {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split "," |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Test-DriveRoot {
    param([string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    $rootPath = [IO.Path]::GetPathRoot($fullPath).TrimEnd("\")
    return $fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)
}

function Get-IISForgeInstallRoot {
    if ((Split-Path -Leaf $PSScriptRoot) -ieq "scripts") {
        return (Split-Path -Parent $PSScriptRoot)
    }

    return $PSScriptRoot
}

function ConvertTo-IISForgeIisSelector {
    param(
        [string]$SiteName,
        [string]$IisPath
    )

    $site = $SiteName
    $applicationPath = "/"

    if (-not [string]::IsNullOrWhiteSpace($IisPath)) {
        $path = $IisPath.Trim()
        if ($path -match "^[A-Za-z]:[\\/]") {
            throw "'$IisPath' is a disk path. IIS object path should be blank, 'IIS:\Sites\<site>', or 'IIS:\Sites\<site>\<app>'."
        }

        $path = $path -replace "^IIS:\\Sites\\", ""
        $path = $path -replace "^IIS:/Sites/", ""
        $path = $path.Trim("\", "/")

        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $parts = $path -split "[\\/]", 2
            $site = $parts[0]
            if ($parts.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($parts[1])) {
                $applicationPath = "/" + ($parts[1] -replace "\\", "/").Trim("/")
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($site)) {
        throw "IIS site name is required."
    }

    return [pscustomobject]@{
        SiteName = $site
        ApplicationPath = $applicationPath
    }
}

function Get-IISForgeCurrentIisTarget {
    param(
        [string]$SiteName,
        [string]$IisPath
    )

    try {
        try {
            Add-Type -AssemblyName "Microsoft.Web.Administration" -ErrorAction Stop
        }
        catch {
            $candidatePaths = @(
                (Join-Path $env:windir "System32\inetsrv\Microsoft.Web.Administration.dll"),
                (Join-Path $env:windir "SysWOW64\inetsrv\Microsoft.Web.Administration.dll")
            )

            $loaded = $false
            foreach ($candidatePath in $candidatePaths) {
                if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                    Add-Type -Path $candidatePath -ErrorAction Stop
                    $loaded = $true
                    break
                }
            }

            if (-not $loaded) {
                return $null
            }
        }

        $selector = ConvertTo-IISForgeIisSelector -SiteName $SiteName -IisPath $IisPath
        $manager = New-Object Microsoft.Web.Administration.ServerManager
        $site = $manager.Sites | Where-Object { $_.Name -eq $selector.SiteName } | Select-Object -First 1
        if (-not $site) {
            Write-Host "IIS site '$($selector.SiteName)' was not found. The deploy engine will check again during deployment." -ForegroundColor Yellow
            return $null
        }

        $application = $site.Applications | Where-Object { $_.Path -eq $selector.ApplicationPath } | Select-Object -First 1
        if (-not $application) {
            Write-Host "IIS application '$($selector.ApplicationPath)' was not found under site '$($selector.SiteName)'." -ForegroundColor Yellow
            return $null
        }

        $virtualDirectory = $application.VirtualDirectories | Where-Object { $_.Path -eq "/" } | Select-Object -First 1
        if (-not $virtualDirectory) {
            return $null
        }

        $physicalPath = [Environment]::ExpandEnvironmentVariables($virtualDirectory.PhysicalPath)
        return [pscustomobject]@{
            PhysicalPath = $physicalPath
            AppPoolName = $application.ApplicationPoolName
        }
    }
    catch {
        Write-Host "Could not read current IIS physical path now: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Test-IISForgePathUnderRoot {
    param(
        [string]$Path,
        [string]$RootPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($RootPath)) {
        return $false
    }

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
    $fullRoot = [IO.Path]::GetFullPath($RootPath).TrimEnd("\", "/")

    return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-IISForgeEngine {
    param([string]$RootPath)

    $expectedEnginePath = Join-Path $RootPath "iis-forge.ps1"
    $legacyScriptsRoot = Join-Path $RootPath "scripts"
    $legacyEnginePath = Join-Path $legacyScriptsRoot "iis-forge.ps1"

    if (Test-Path -LiteralPath $expectedEnginePath -PathType Leaf) {
        return $expectedEnginePath
    }

    if (Test-Path -LiteralPath $legacyEnginePath -PathType Leaf) {
        Copy-Item -LiteralPath $legacyEnginePath -Destination $expectedEnginePath -Force
        Write-Host "Copied IIS Forge engine to flat install root: $expectedEnginePath"
        return $expectedEnginePath
    }

    $localEnginePath = Join-Path $PSScriptRoot "iis-forge.ps1"
    if ((Test-Path -LiteralPath $localEnginePath -PathType Leaf) -and
        -not $localEnginePath.Equals($expectedEnginePath, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $localEnginePath -Destination $expectedEnginePath -Force
        Write-Host "Restored IIS Forge engine: $expectedEnginePath"
        return $expectedEnginePath
    }

    Write-Host "IIS Forge engine missing. Downloading latest engine into $expectedEnginePath"
    try {
        Invoke-WebRequest `
            -Uri "https://raw.githubusercontent.com/sduddupudi/IIS-Forge/main/iis-forge.ps1" `
            -OutFile $expectedEnginePath `
            -UseBasicParsing `
            -TimeoutSec 60
    }
    catch {
        throw "IIS Forge engine is missing at '$expectedEnginePath' and automatic download failed. Run 'git pull' from '$RootPath' or copy iis-forge.ps1 into '$RootPath'. Details: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $expectedEnginePath -PathType Leaf)) {
        throw "IIS Forge engine restore failed: $expectedEnginePath"
    }

    return $expectedEnginePath
}

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Get-IISForgeInstallRoot
}

$InstallRoot = (Resolve-Path -LiteralPath $InstallRoot).Path

if (Test-DriveRoot -Path $InstallRoot) {
    $currentPath = (Get-Location).Path
    $currentLooksLikeInstallRoot = -not (Test-DriveRoot -Path $currentPath) -and
        ((Test-Path -LiteralPath (Join-Path $currentPath "iis-forge.ps1") -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $currentPath "scripts\iis-forge.ps1") -PathType Leaf))

    if (-not $PSBoundParameters.ContainsKey("InstallRoot") -and $currentLooksLikeInstallRoot) {
        $InstallRoot = (Resolve-Path -LiteralPath $currentPath).Path
    }
    else {
        Write-Host ""
        Write-Host "IIS Forge install root resolved to '$InstallRoot', which would create files at the drive root." -ForegroundColor Yellow
        Write-Host "Choose the folder that contains IIS Forge. Do not use a drive root."

        do {
            $InstallRoot = Read-IisForgeValue -Prompt "IIS Forge install root folder" -DefaultValue $currentPath
            if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
                Write-Host "Folder does not exist: $InstallRoot"
                continue
            }

            $InstallRoot = (Resolve-Path -LiteralPath $InstallRoot).Path
            if (Test-DriveRoot -Path $InstallRoot) {
                Write-Host "Do not use a drive root. Use the folder where IIS Forge is installed."
                continue
            }

            break
        } while ($true)
    }
}

$enginePath = Initialize-IISForgeEngine -RootPath $InstallRoot

$profilesRoot = Join-Path $InstallRoot "profiles"
$reposRoot = Join-Path $InstallRoot "repos"
$releasesRoot = Join-Path $InstallRoot "releases"

New-Item -ItemType Directory -Path $profilesRoot, $reposRoot, $releasesRoot -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($ProfileName)) {
    $ProfileName = Read-IisForgeValue -Prompt "Profile name, usually IIS site name"
}

$ProfileName = ConvertTo-IisForgeSlug -Value $ProfileName
$profilePath = Join-Path $profilesRoot "$ProfileName.json"
$launcherPath = Join-Path $InstallRoot "$ProfileName.deploy.ps1"

if ((Test-Path -LiteralPath $profilePath) -and -not $Configure) {
    throw "Profile already exists: $profilePath. Re-run with -Configure to overwrite it."
}

$defaultRepoPath = Join-Path "repos" $ProfileName
$defaultReleaseRoot = Join-Path "releases" $ProfileName
$defaultBackupPath = Join-Path "backups" $ProfileName

Write-Host ""
Write-Host "IIS Forge profile wizard"
Write-Host "Profile: $ProfileName"
Write-Host "Install root: $InstallRoot"
Write-Host "IIS Forge deploys to release folders under this install root, then points IIS at the newest release."
Write-Host "Press Enter to accept defaults."
Write-Host ""

$repoUrl = Read-IisForgeValue -Prompt "Git repository URL"
$branch = Read-IisForgeValue -Prompt "Git branch" -DefaultValue "main"
$siteName = Read-IisForgeValue -Prompt "IIS site name" -DefaultValue $ProfileName
$iisPath = Read-IisForgeValue -Prompt "IIS site/app selector, blank = use site name; only use IIS:\Sites\site\app for sub-apps" -DefaultValue "" -AllowEmpty
$currentIisTarget = Get-IISForgeCurrentIisTarget -SiteName $siteName -IisPath $iisPath
if ($currentIisTarget -and -not [string]::IsNullOrWhiteSpace($currentIisTarget.PhysicalPath)) {
    Write-Host "Current IIS website folder: $($currentIisTarget.PhysicalPath)"
    Write-Host "After deploy, IIS will point to a new release folder instead of this folder."
}

$defaultAppPoolName = $siteName
if ($currentIisTarget -and -not [string]::IsNullOrWhiteSpace($currentIisTarget.AppPoolName)) {
    $defaultAppPoolName = $currentIisTarget.AppPoolName
}
$appPoolName = Read-IisForgeValue -Prompt "IIS app pool name" -DefaultValue $defaultAppPoolName -AllowEmpty
$repoPath = Read-IisForgeValue -Prompt "Git clone folder for source code, relative to install root unless absolute" -DefaultValue $defaultRepoPath
$projectPath = Read-IisForgeValue -Prompt "Project path, blank = auto-detect first .csproj" -DefaultValue "" -AllowEmpty
$solutionPath = Read-IisForgeValue -Prompt "Solution path, blank = auto-detect first .sln" -DefaultValue "" -AllowEmpty
$staticPublishPath = Read-IisForgeValue -Prompt "Repo build output folder for static-only sites, blank for .NET apps or auto-detect dist/build/public/wwwroot/out" -DefaultValue "" -AllowEmpty
$releaseRoot = Read-IisForgeValue -Prompt "IIS Forge release folders root, relative to install root unless absolute" -DefaultValue $defaultReleaseRoot
$runtimeIdentifier = Read-IisForgeValue -Prompt "Runtime identifier, blank = framework-dependent portable publish" -DefaultValue "win-x64" -AllowEmpty
$configuration = Read-IisForgeValue -Prompt "Build configuration" -DefaultValue "Release"
$keepReleases = [int](Read-IisForgeValue -Prompt "Releases to keep" -DefaultValue "5")
$preserveFiles = Split-PreserveFiles -Value (Read-IisForgeValue -Prompt "Preserve files, comma-separated" -DefaultValue "appsettings.Production.json" -AllowEmpty)
$overlayPath = Read-IisForgeValue -Prompt "Secure config overlay folder, blank = none" -DefaultValue "" -AllowEmpty
$backupDefault = ""
if ($currentIisTarget -and -not [string]::IsNullOrWhiteSpace($currentIisTarget.PhysicalPath)) {
    $releaseRootFullPath = if ([IO.Path]::IsPathRooted($releaseRoot)) {
        [IO.Path]::GetFullPath($releaseRoot)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $InstallRoot $releaseRoot))
    }

    if (Test-IISForgePathUnderRoot -Path $currentIisTarget.PhysicalPath -RootPath $releaseRootFullPath) {
        Write-Host "Current IIS website folder is already managed by IIS Forge releases; backup source default is none."
    }
    else {
        $backupDefault = $currentIisTarget.PhysicalPath
    }
}
$backupOnlyWhen = Read-IisForgeValue -Prompt "Old IIS website folder to back up once, type none to skip" -DefaultValue $backupDefault -AllowEmpty
if ($backupOnlyWhen -ieq "none") {
    $backupOnlyWhen = ""
}
$backupTo = ""
if (-not [string]::IsNullOrWhiteSpace($backupOnlyWhen)) {
    $backupTo = Read-IisForgeValue -Prompt "Backup destination folder, relative to install root unless absolute" -DefaultValue $defaultBackupPath
}

$profile = [ordered]@{
    ProfileName = $ProfileName
    GitRepositoryUrl = $repoUrl
    Branch = $branch
    Remote = "origin"
    SiteName = $siteName
    IisPath = $iisPath
    AppPoolName = $appPoolName
    RepoPath = $repoPath
    ProjectPath = $projectPath
    SolutionPath = $solutionPath
    StaticPublishPath = $staticPublishPath
    ReleasesRoot = $releaseRoot
    Configuration = $configuration
    RuntimeIdentifier = $runtimeIdentifier
    SelfContained = $false
    KeepReleases = $keepReleases
    ConfigOverlayPath = $overlayPath
    PreserveFiles = $preserveFiles
    BackupPreviousPhysicalPathOnlyWhen = $backupOnlyWhen
    BackupPreviousPhysicalPathTo = $backupTo
    InstallMissingDependencies = $true
    DiscardLocalChanges = $true
    SkipBrowserslistUpdate = $true
    DisableConsoleQuickEdit = $true
}

$profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $profilePath -Encoding UTF8

$launcher = @"
<#
.SYNOPSIS
Deploys the IIS Forge profile '$ProfileName'.
#>

param(
    [string]`$Branch = "",
    [switch]`$RunTests,
    [switch]`$SkipGitPull,
    [switch]`$SkipNpmInstall,
    [switch]`$SkipNpmBuild,
    [switch]`$ForceNpmInstall,
    [switch]`$AllowDirty,
    [switch]`$OverwritePreviousPhysicalPathBackup,
    [switch]`$NoProgress
)

`$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-IISForgeEnginePath {
    param([string]`$RootPath)

    `$candidateEngines = @(
        (Join-Path `$RootPath "iis-forge.ps1"),
        (Join-Path `$RootPath "scripts\iis-forge.ps1")
    )

    foreach (`$candidateEngine in `$candidateEngines) {
        if (Test-Path -LiteralPath `$candidateEngine -PathType Leaf) {
            return `$candidateEngine
        }
    }

    return ""
}

`$candidateRoots = @(
    `$PSScriptRoot,
    (Get-Location).Path
)

if ((Split-Path -Leaf `$PSScriptRoot) -ieq "scripts") {
    `$candidateRoots += Split-Path -Parent `$PSScriptRoot
}

`$candidateRoots = `$candidateRoots |
    Where-Object { -not [string]::IsNullOrWhiteSpace(`$_) } |
    ForEach-Object { [IO.Path]::GetFullPath(`$_) } |
    Select-Object -Unique

`$installRoot = ""
`$profilePath = ""
`$enginePath = ""

foreach (`$root in `$candidateRoots) {
    `$candidateProfile = Join-Path `$root "profiles\$ProfileName.json"
    `$candidateEngine = Get-IISForgeEnginePath -RootPath `$root

    if ((Test-Path -LiteralPath `$candidateProfile -PathType Leaf) -and
        -not [string]::IsNullOrWhiteSpace(`$candidateEngine)) {
        `$installRoot = `$root
        `$profilePath = `$candidateProfile
        `$enginePath = `$candidateEngine
        break
    }
}

if ([string]::IsNullOrWhiteSpace(`$profilePath)) {
    throw "Profile file not found. Keep this launcher in the IIS Forge install root or regenerate it from that folder."
}

if ([string]::IsNullOrWhiteSpace(`$enginePath)) {
    throw "IIS Forge engine not found next to this launcher. Restore iis-forge.ps1 in the install root or regenerate the launcher."
}

`$profile = Get-Content -LiteralPath `$profilePath -Raw | ConvertFrom-Json

`$arguments = @{
    RepoPath = [string]`$profile.RepoPath
    ProjectPath = [string]`$profile.ProjectPath
    SolutionPath = [string]`$profile.SolutionPath
    StaticPublishPath = [string]`$profile.StaticPublishPath
    Remote = [string]`$profile.Remote
    Branch = [string]`$profile.Branch
    GitHubRepositoryUrl = [string]`$profile.GitRepositoryUrl
    SiteName = [string]`$profile.SiteName
    IisPath = [string]`$profile.IisPath
    AppPoolName = [string]`$profile.AppPoolName
    ReleasesRoot = [string]`$profile.ReleasesRoot
    Configuration = [string]`$profile.Configuration
    RuntimeIdentifier = [string]`$profile.RuntimeIdentifier
    SelfContained = [bool]`$profile.SelfContained
    KeepReleases = [int]`$profile.KeepReleases
    ConfigOverlayPath = [string]`$profile.ConfigOverlayPath
    PreserveFiles = @(`$profile.PreserveFiles)
    BackupPreviousPhysicalPathTo = [string]`$profile.BackupPreviousPhysicalPathTo
    BackupPreviousPhysicalPathOnlyWhen = [string]`$profile.BackupPreviousPhysicalPathOnlyWhen
    InstallMissingDependencies = [bool]`$profile.InstallMissingDependencies
    DiscardLocalChanges = [bool]`$profile.DiscardLocalChanges
    DisableConsoleQuickEdit = [bool]`$profile.DisableConsoleQuickEdit
}

if (-not [string]::IsNullOrWhiteSpace(`$Branch)) {
    `$arguments.Branch = `$Branch
}
if ([bool]`$profile.SkipBrowserslistUpdate) {
    `$arguments.SkipBrowserslistUpdate = `$true
}
if (`$RunTests) { `$arguments.RunTests = `$true }
if (`$SkipGitPull) { `$arguments.SkipGitPull = `$true }
if (`$SkipNpmInstall) { `$arguments.SkipNpmInstall = `$true }
if (`$SkipNpmBuild) { `$arguments.SkipNpmBuild = `$true }
if (`$ForceNpmInstall) { `$arguments.ForceNpmInstall = `$true }
if (`$AllowDirty) { `$arguments.AllowDirty = `$true }
if (`$OverwritePreviousPhysicalPathBackup) { `$arguments.OverwritePreviousPhysicalPathBackup = `$true }
if (`$NoProgress) { `$arguments.NoProgress = `$true }

& `$enginePath @arguments
"@

Set-Content -LiteralPath $launcherPath -Value $launcher -Encoding UTF8

Write-Host ""
Write-Host "Created profile: $profilePath"
Write-Host "Created launcher: $launcherPath"
Write-Host ""
Write-Host "Deploy with:"
Write-Host "powershell -ExecutionPolicy Bypass -File `"$launcherPath`""
