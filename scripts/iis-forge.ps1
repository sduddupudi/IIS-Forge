<#
.SYNOPSIS
Pulls a Git branch, builds/publishes a web app, and switches an IIS site or application to a new release folder.

.DESCRIPTION
IIS Forge is a release-folder deployment engine for IIS. It is designed for repeatable
server-side deploys without Visual Studio publish.

The engine can:
- clone or pull a Git repository
- install missing Git, Node.js, .NET SDK, ASP.NET Core Hosting Bundle, and IIS management tooling
- detect the .NET major version from TargetFramework/TargetFrameworks or global.json
- run npm install/build when package.json exists
- publish ASP.NET Core projects when a .csproj exists
- switch the IIS physical path to a timestamped release folder
- recycle the app pool
- preserve config files and apply a secure config overlay

It intentionally does not run HTTP health checks. App-specific verification belongs outside
the universal deploy engine.

.EXAMPLE
.\iis-forge.ps1 `
    -SiteName "example.com" `
    -AppPoolName "example.com" `
    -GitHubRepositoryUrl "https://github.com/example/example.com.git"

.EXAMPLE
.\iis-forge.ps1 `
    -SiteName "example.com" `
    -Branch "staging" `
    -RunTests `
    -NoProgress `
    -PreserveFiles @("appsettings.Production.json")
#>

param(
    [string]$RepoPath = "",
    [string]$ProjectPath = "",
    [string]$SolutionPath = "",
    [string]$StaticPublishPath = "",
    [string]$Remote = "origin",
    [string]$Branch = "main",
    [string]$GitHubRepositoryUrl = "",

    [string]$SiteName = "",

    [string]$IisPath = "",
    [string]$AppPoolName = "",
    [string]$ReleasesRoot = "",
    [string]$Configuration = "Release",
    [string]$RuntimeIdentifier = "win-x64",
    [bool]$SelfContained = $false,
    [int]$KeepReleases = 5,

    [string]$ConfigOverlayPath = "",
    [string[]]$PreserveFiles = @("appsettings.Production.json"),
    [string]$BackupPreviousPhysicalPathTo = "",
    [string]$BackupPreviousPhysicalPathOnlyWhen = "",
    [switch]$OverwritePreviousPhysicalPathBackup,

    [switch]$RunTests,
    [switch]$SkipGitPull,
    [switch]$SkipNpmInstall,
    [switch]$SkipNpmBuild,
    [switch]$ForceNpmInstall,
    [switch]$SkipBrowserslistUpdate,
    [switch]$AllowDirty,
    [switch]$DiscardLocalChanges,
    [switch]$InstallMissingDependencies,
    [bool]$DisableConsoleQuickEdit = $true,
    [switch]$NoProgress
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$env:CI = "true"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:NPM_CONFIG_FUND = "false"
$env:NPM_CONFIG_AUDIT = "false"
$env:NPM_CONFIG_PROGRESS = "false"
$env:BROWSERSLIST_IGNORE_OLD_DATA = "true"

$script:DeploymentStartedAt = Get-Date
$script:DeployStepIndex = 0
$script:DeployStepTotal = 11

function Disable-ConsoleQuickEditMode {
    if (-not $DisableConsoleQuickEdit) {
        return
    }

    try {
        if (-not ("ConsoleMode.NativeMethods" -as [type])) {
            Add-Type -TypeDefinition @"
namespace ConsoleMode {
    using System;
    using System.Runtime.InteropServices;

    public static class NativeMethods {
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);
    }
}
"@
        }

        $stdInputHandle = [ConsoleMode.NativeMethods]::GetStdHandle(-10)
        $mode = 0
        if ([ConsoleMode.NativeMethods]::GetConsoleMode($stdInputHandle, [ref]$mode)) {
            $enableQuickEdit = 0x0040
            $enableExtendedFlags = 0x0080
            $newMode = ($mode -bor $enableExtendedFlags) -band (-bnot $enableQuickEdit)
            [ConsoleMode.NativeMethods]::SetConsoleMode($stdInputHandle, $newMode) | Out-Null
        }
    }
    catch {
        Write-Verbose "Could not disable console QuickEdit mode: $($_.Exception.Message)"
    }
}

Disable-ConsoleQuickEditMode

function Format-Elapsed {
    param([TimeSpan]$Elapsed)

    return "{0:00}:{1:00}:{2:00}" -f [Math]::Floor($Elapsed.TotalHours), $Elapsed.Minutes, $Elapsed.Seconds
}

function Write-Step {
    param([string]$Message)

    $script:DeployStepIndex++
    $percent = [Math]::Min(99, [Math]::Floor(($script:DeployStepIndex / $script:DeployStepTotal) * 100))
    $elapsed = Format-Elapsed -Elapsed ((Get-Date) - $script:DeploymentStartedAt)

    Write-Host ""
    Write-Host ("[{0}/{1}] {2}  elapsed={3}" -f $script:DeployStepIndex.ToString("00"), $script:DeployStepTotal.ToString("00"), $Message, $elapsed)

    if (-not $NoProgress) {
        Write-Progress -Activity "IIS deployment" -Status $Message -PercentComplete $percent
    }
}

function Complete-DeployProgress {
    if (-not $NoProgress) {
        Write-Progress -Activity "IIS deployment" -Completed
    }
}

function Get-ToolCandidatePaths {
    param([string]$Name)

    $programFilesRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)}
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

    $candidatePaths = @()
    switch ($Name.ToLowerInvariant()) {
        "git" {
            foreach ($root in $programFilesRoots) {
                $candidatePaths += Join-Path $root "Git\cmd\git.exe"
                $candidatePaths += Join-Path $root "Git\bin\git.exe"
            }
        }
        "dotnet" {
            foreach ($root in $programFilesRoots) {
                $candidatePaths += Join-Path $root "dotnet\dotnet.exe"
            }
        }
        "npm.cmd" {
            foreach ($root in $programFilesRoots) {
                $candidatePaths += Join-Path $root "nodejs\npm.cmd"
            }
        }
    }

    return $candidatePaths
}

function Get-RequiredCommand {
    param([string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        $candidatePaths = Get-ToolCandidatePaths -Name $Name

        foreach ($candidatePath in $candidatePaths) {
            if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
                return $candidatePath
            }
        }

        throw "Required command '$Name' was not found in PATH or common install locations. Install it or add it to PATH."
    }

    return $command.Source
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath) -join ";"
}

function Invoke-WingetInstall {
    param(
        [string]$PackageId,
        [string]$DisplayName
    )

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        if ($PackageId -eq "Git.Git") {
            Install-GitFromGitHub
            return
        }
        if ($PackageId -eq "OpenJS.NodeJS.LTS") {
            Install-NodeFromNodeJs
            return
        }
        if ($PackageId -match "^Microsoft\.DotNet\.SDK\.(?<major>\d+)$") {
            Install-DotNetSdkFromScript -Major ([int]$Matches.major)
            return
        }
        if ($PackageId -match "^Microsoft\.DotNet\.HostingBundle\.(?<major>\d+)$") {
            Install-DotNetHostingBundleFromAkaMs -Major ([int]$Matches.major)
            return
        }

        throw "$DisplayName is missing and winget.exe was not found. Install winget/App Installer or install $DisplayName manually."
    }

    Write-Host "Installing $DisplayName with winget package '$PackageId'."
    & $winget.Source install --id $PackageId --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget install failed for $DisplayName with exit code $LASTEXITCODE."
    }

    Refresh-ProcessPath
}

function Install-NodeFromNodeJs {
    Write-Host "winget.exe not found. Downloading latest Node.js LTS x64 MSI from nodejs.org."

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $versions = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -TimeoutSec 60
    $version = $versions |
        Where-Object { $_.lts -and $_.files -contains "win-x64-msi" } |
        Select-Object -First 1

    if (-not $version) {
        throw "Could not find a Node.js LTS x64 MSI from nodejs.org."
    }

    $msiName = "node-$($version.version)-x64.msi"
    $installerUrl = "https://nodejs.org/dist/$($version.version)/$msiName"
    $installerPath = Join-Path $env:TEMP $msiName

    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

    Write-Host "Installing Node.js $($version.version) from $installerPath"
    $process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList @("/i", $installerPath, "/qn", "/norestart") `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Node.js installer failed with exit code $($process.ExitCode)."
    }

    Refresh-ProcessPath
}

function Install-DotNetSdkFromScript {
    param([int]$Major)

    Write-Host "winget.exe not found. Installing .NET $Major SDK with dotnet-install.ps1."

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installScript = Join-Path $env:TEMP "dotnet-install.ps1"
    Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installScript -UseBasicParsing

    $installDir = Join-Path $env:ProgramFiles "dotnet"
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript -Channel "$Major.0" -InstallDir $installDir
    if ($LASTEXITCODE -ne 0) {
        throw ".NET SDK install script failed with exit code $LASTEXITCODE."
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($machinePath -notlike "*$installDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$machinePath;$installDir", "Machine")
    }

    Refresh-ProcessPath
}

function Install-DotNetHostingBundleFromAkaMs {
    param([int]$Major)

    Write-Host "winget.exe not found. Downloading .NET $Major Hosting Bundle from aka.ms."

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installerPath = Join-Path $env:TEMP "dotnet-hosting-$Major.0-win.exe"
    Invoke-WebRequest -Uri "https://aka.ms/dotnet/$Major.0/dotnet-hosting-win.exe" -OutFile $installerPath -UseBasicParsing

    $process = Start-Process `
        -FilePath $installerPath `
        -ArgumentList @("/quiet", "/norestart") `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw ".NET Hosting Bundle installer failed with exit code $($process.ExitCode)."
    }

    Refresh-ProcessPath
}

function Install-GitFromGitHub {
    Write-Host "winget.exe not found. Downloading latest Git for Windows installer from GitHub."

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/git-for-windows/git/releases/latest" `
        -Headers @{ "User-Agent" = "iis-forge" } `
        -TimeoutSec 60

    $asset = $release.assets |
        Where-Object { $_.name -match "^Git-.+-64-bit\.exe$" } |
        Select-Object -First 1

    if (-not $asset) {
        throw "Could not find Git for Windows 64-bit installer in latest GitHub release."
    }

    $installerPath = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installerPath -UseBasicParsing

    Write-Host "Installing Git from $installerPath"
    $process = Start-Process `
        -FilePath $installerPath `
        -ArgumentList @("/VERYSILENT", "/NORESTART", "/NOCANCEL", "/SP-") `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Git installer failed with exit code $($process.ExitCode)."
    }

    Refresh-ProcessPath
}

function Ensure-Command {
    param(
        [string]$Name,
        [string]$PackageId,
        [string]$DisplayName
    )

    try {
        return Get-RequiredCommand -Name $Name
    }
    catch {
        if (-not $InstallMissingDependencies) {
            throw
        }

        Invoke-WingetInstall -PackageId $PackageId -DisplayName $DisplayName
        return Get-RequiredCommand -Name $Name
    }
}

function Get-ProjectDotNetMajor {
    param([string]$Path)

    try {
        [xml]$projectXml = Get-Content -LiteralPath $Path -Raw
        $majors = @()

        $targetNodes = $projectXml.SelectNodes("/*[local-name()='Project']/*[local-name()='PropertyGroup']/*[local-name()='TargetFramework' or local-name()='TargetFrameworks']")
        foreach ($targetNode in $targetNodes) {
            if (-not [string]::IsNullOrWhiteSpace($targetNode.InnerText)) {
                foreach ($framework in ($targetNode.InnerText -split ";")) {
                    if ($framework -match "^net(?<major>\d+)\.") {
                        $majors += [int]$Matches.major
                    }
                }
            }
        }

        if ($majors.Count -gt 0) {
            return ($majors | Sort-Object -Descending | Select-Object -First 1)
        }
    }
    catch {
        Write-Warning "Could not read target framework from '$Path': $($_.Exception.Message)"
    }

    return 0
}

function Get-GlobalJsonDotNetMajor {
    param([string]$RootPath)

    $globalJsonPath = Join-Path $RootPath "global.json"
    if (-not (Test-Path -LiteralPath $globalJsonPath -PathType Leaf)) {
        return 0
    }

    try {
        $globalJson = Get-Content -LiteralPath $globalJsonPath -Raw | ConvertFrom-Json
        $sdkVersion = [string]$globalJson.sdk.version
        if ($sdkVersion -match "^(?<major>\d+)\.") {
            return [int]$Matches.major
        }
    }
    catch {
        Write-Warning "Could not read SDK version from '$globalJsonPath': $($_.Exception.Message)"
    }

    return 0
}

function Resolve-DotNetMajor {
    param(
        [string]$ProjectFile,
        [string]$RootPath
    )

    $major = Get-ProjectDotNetMajor -Path $ProjectFile
    if ($major -gt 0) {
        return $major
    }

    $major = Get-GlobalJsonDotNetMajor -RootPath $RootPath
    if ($major -gt 0) {
        return $major
    }

    throw "Could not determine .NET major version. Add TargetFramework/TargetFrameworks to '$ProjectFile' or sdk.version to '$RootPath\global.json'."
}

function Test-DotNetSdkMajorInstalled {
    param(
        [string]$DotNetCommand,
        [int]$Major
    )

    $sdkLines = & $DotNetCommand --list-sdks
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list installed .NET SDKs."
    }

    foreach ($line in $sdkLines) {
        if ($line -match "^(?<major>\d+)\.") {
            if ([int]$Matches.major -eq $Major) {
                return $true
            }
        }
    }

    return $false
}

function Test-AspNetCoreRuntimeMajorInstalled {
    param(
        [string]$DotNetCommand,
        [int]$Major
    )

    if ($Major -le 0) {
        return $true
    }

    $runtimeLines = & $DotNetCommand --list-runtimes
    if ($LASTEXITCODE -ne 0) {
        throw "Could not list installed .NET runtimes."
    }

    foreach ($line in $runtimeLines) {
        if ($line -match "^Microsoft\.AspNetCore\.App\s+(?<major>\d+)\.") {
            if ([int]$Matches.major -eq $Major) {
                return $true
            }
        }
    }

    return $false
}

function Ensure-DotNetSdkMajor {
    param(
        [string]$DotNetCommand,
        [int]$Major
    )

    if ($Major -le 0) {
        return $DotNetCommand
    }

    if (Test-DotNetSdkMajorInstalled -DotNetCommand $DotNetCommand -Major $Major) {
        return $DotNetCommand
    }

    if (-not $InstallMissingDependencies) {
        throw ".NET SDK $Major is required by the project, but it is not installed. Install .NET SDK $Major or pass -InstallMissingDependencies."
    }

    Invoke-WingetInstall -PackageId "Microsoft.DotNet.SDK.$Major" -DisplayName ".NET SDK $Major"
    $DotNetCommand = Get-RequiredCommand -Name "dotnet"

    if (-not (Test-DotNetSdkMajorInstalled -DotNetCommand $DotNetCommand -Major $Major)) {
        throw ".NET SDK $Major install completed, but dotnet --list-sdks still does not show SDK $Major."
    }

    return $DotNetCommand
}

function Initialize-DotNetSdkSelection {
    param(
        [string]$RootPath,
        [int]$Major
    )

    if ($Major -le 0) {
        return $RootPath
    }

    $pinDirectory = Join-Path (Join-Path $PSScriptRoot ".cache") "dotnet-sdk\net$Major"
    New-Item -ItemType Directory -Path $pinDirectory -Force | Out-Null

    $globalJson = [ordered]@{
        sdk = [ordered]@{
            version = "$Major.0.100"
            rollForward = "latestFeature"
            allowPrerelease = $false
        }
    }

    $globalJson |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $pinDirectory "global.json") -Encoding UTF8

    return $pinDirectory
}

function Ensure-IisManagement {
    if (Get-Module -ListAvailable WebAdministration) {
        Import-Module WebAdministration -Force -Global -ErrorAction Stop
        if (Get-PSDrive -Name IIS -ErrorAction SilentlyContinue) {
            return
        }

        Write-Warning "WebAdministration module exists, but IIS:\ drive is not loaded. Reinstalling/enabling IIS scripting tools."
    }
    else {
        Write-Host "WebAdministration module not found."
    }

    if ((Get-Module -ListAvailable WebAdministration) -and -not $InstallMissingDependencies) {
        Import-Module WebAdministration -Force -Global -ErrorAction Stop
        if (Get-PSDrive -Name IIS -ErrorAction SilentlyContinue) {
            return
        }

        throw "IIS:\ drive is missing after importing WebAdministration. Run elevated Windows PowerShell and install IIS Management Scripts and Tools."
    }

    if ((Get-Module -ListAvailable WebAdministration) -and $InstallMissingDependencies) {
        # Continue through install/repair path below.
    }
    elseif (Get-Module -ListAvailable WebAdministration) {
        return
    }

    if (-not $InstallMissingDependencies) {
        throw "IIS WebAdministration module is missing. Install IIS Management Scripts and Tools."
    }

    Write-Host "Installing IIS Management Scripts and Tools."
    $serverManager = Get-Module -ListAvailable ServerManager
    if ($serverManager) {
        Import-Module ServerManager -ErrorAction Stop
        Install-WindowsFeature Web-Server, Web-Mgmt-Tools, Web-Scripting-Tools -IncludeManagementTools | Out-Host
    }
    else {
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementScriptingTools -All -NoRestart | Out-Host
    }

    Import-Module WebAdministration -Force -Global -ErrorAction Stop

    if (-not (Get-PSDrive -Name IIS -ErrorAction SilentlyContinue)) {
        throw "IIS:\ drive still missing after install attempt. Restart PowerShell/server, then run again from elevated Windows PowerShell."
    }
}

function Ensure-AspNetCoreHostingBundle {
    param(
        [string]$DotNetCommand,
        [int]$Major
    )

    if (-not $InstallMissingDependencies) {
        return
    }

    $aspNetCoreModulePath = Join-Path $env:ProgramFiles "IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"
    $hasAspNetCoreModule = Test-Path -LiteralPath $aspNetCoreModulePath -PathType Leaf
    $hasAspNetCoreRuntime = Test-AspNetCoreRuntimeMajorInstalled -DotNetCommand $DotNetCommand -Major $Major

    if ($hasAspNetCoreModule -and $hasAspNetCoreRuntime) {
        return
    }

    if ($Major -le 0) {
        Write-Warning "Could not determine target .NET runtime major. Skipping automatic Hosting Bundle install."
        return
    }

    Invoke-WingetInstall -PackageId "Microsoft.DotNet.HostingBundle.$Major" -DisplayName ".NET $Major Hosting Bundle"
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Write-Host ("> {0} {1}" -f $FilePath, ($Arguments -join " "))

    Push-Location $WorkingDirectory
    $previousPath = $env:Path
    try {
        $pathParts = @()

        $toolDirectory = Split-Path -Parent $FilePath
        if (-not [string]::IsNullOrWhiteSpace($toolDirectory) -and (Test-Path -LiteralPath $toolDirectory)) {
            $pathParts += $toolDirectory
        }

        $nodeModulesBin = Join-Path $WorkingDirectory "node_modules\.bin"
        if (Test-Path -LiteralPath $nodeModulesBin) {
            $pathParts += $nodeModulesBin
        }

        $nodeInstallDirectories = Get-ToolCandidatePaths -Name "npm.cmd" |
            ForEach-Object { Split-Path -Parent $_ } |
            Select-Object -Unique
        foreach ($nodeInstallDirectory in $nodeInstallDirectories) {
            if (Test-Path -LiteralPath $nodeInstallDirectory) {
                $pathParts += $nodeInstallDirectory
            }
        }

        if ($pathParts.Count -gt 0) {
            $env:Path = (($pathParts | Select-Object -Unique) -join ";") + ";" + $env:Path
        }

        $env:CI = "true"
        $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
        $env:NPM_CONFIG_FUND = "false"
        $env:NPM_CONFIG_AUDIT = "false"
        $env:NPM_CONFIG_PROGRESS = "false"
        $env:BROWSERSLIST_IGNORE_OLD_DATA = "true"

        & $FilePath @Arguments
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "'$FilePath' failed with exit code $exitCode."
        }
    }
    finally {
        $env:Path = $previousPath
        Pop-Location
    }
}

function Get-GitRemoteUrl {
    param(
        [string]$GitCommand,
        [string]$RootPath,
        [string]$RemoteName
    )

    $remoteUrl = (& $GitCommand -C $RootPath remote get-url $RemoteName 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
        throw "Git remote '$RemoteName' was not found."
    }

    return $remoteUrl.Trim()
}

function Normalize-GitHubRemoteUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    $normalized = $Url.Trim().ToLowerInvariant()
    $normalized = $normalized -replace "^git@github\.com:", "https://github.com/"
    $normalized = $normalized -replace "^ssh://git@github\.com/", "https://github.com/"
    $normalized = $normalized -replace "\.git$", ""
    $normalized = $normalized.TrimEnd("/")

    return $normalized
}

function Test-GitHubRemote {
    param(
        [string]$RemoteUrl,
        [string]$ExpectedUrl
    )

    if ($RemoteUrl -notmatch "github\.com[:/]") {
        throw "Remote '$RemoteUrl' does not look like a GitHub remote. Check -Remote or pass -SkipGitPull."
    }

    $normalizedRemote = Normalize-GitHubRemoteUrl -Url $RemoteUrl
    $normalizedExpected = Normalize-GitHubRemoteUrl -Url $ExpectedUrl

    if (-not [string]::IsNullOrWhiteSpace($ExpectedUrl) -and $normalizedRemote -ne $normalizedExpected) {
        throw "GitHub remote mismatch. Expected '$ExpectedUrl', found '$RemoteUrl'."
    }
}

function Resolve-SingleProject {
    param([string]$RootPath)

    $projects = @(Get-ChildItem -LiteralPath $RootPath -Filter "*.csproj" -File -Recurse |
        Where-Object {
            $_.FullName -notmatch "\\(bin|obj|node_modules)\\"
        } |
        Where-Object {
            $_.FullName -notmatch "\\[^\\]*(Tests|Test)\\"
        })

    if ($projects.Count -eq 0) {
        return ""
    }

    if ($projects.Count -ne 1) {
        $projectList = ($projects | ForEach-Object { $_.FullName }) -join [Environment]::NewLine
        throw "Could not infer a single deployable project. Pass -ProjectPath explicitly. Candidates:$([Environment]::NewLine)$projectList"
    }

    return $projects[0].FullName
}

function Resolve-StaticPublishRoot {
    param(
        [string]$RootPath,
        [string]$PublishPath
    )

    if (-not [string]::IsNullOrWhiteSpace($PublishPath)) {
        if (-not [IO.Path]::IsPathRooted($PublishPath)) {
            $PublishPath = Join-Path $RootPath $PublishPath
        }

        return (Resolve-Path -LiteralPath $PublishPath).Path
    }

    foreach ($candidate in @("dist", "build", "public", "wwwroot", "out")) {
        $candidatePath = Join-Path $RootPath $candidate
        if (Test-Path -LiteralPath $candidatePath -PathType Container) {
            return (Resolve-Path -LiteralPath $candidatePath).Path
        }
    }

    throw "No .csproj was found and no static publish folder could be inferred. Pass -StaticPublishPath, for example 'dist' or 'build'."
}

function Copy-DirectoryContents {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Static publish folder not found: $SourceRoot"
    }

    Get-ChildItem -LiteralPath $SourceRoot -Force |
        Copy-Item -Destination $DestinationRoot -Recurse -Force
}

function Resolve-OptionalSolution {
    param([string]$RootPath)

    $solutions = @(Get-ChildItem -LiteralPath $RootPath -Filter "*.sln" -File)
    if ($solutions.Count -eq 1) {
        return $solutions[0].FullName
    }

    return ""
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        throw "Run this script from an elevated PowerShell session. IIS site switching requires administrator rights."
    }
}

function Get-IISForgeInstallRoot {
    if ((Split-Path -Leaf $PSScriptRoot) -ieq "scripts") {
        return (Split-Path -Parent $PSScriptRoot)
    }

    return $PSScriptRoot
}

function Get-IISForgeSafeName {
    param([string]$Value)

    $safe = $Value -replace '[\\/:*?"<>|]', "_"
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return "site"
    }

    return $safe
}

function Resolve-IISForgePath {
    param(
        [string]$Path,
        [string]$BasePath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }

    return [IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Repair-AccidentalIisPathInputs {
    $installRoot = Get-IISForgeInstallRoot
    $safeSiteName = Get-IISForgeSafeName -Value $SiteName

    if ($RepoPath -match "^IIS:") {
        Write-Warning "RepoPath was set to an IIS object path. Resetting to install-root repo path."
        $script:RepoPath = Join-Path (Join-Path $installRoot "repos") $safeSiteName
    }

    if ($ReleasesRoot -match "^IIS:") {
        Write-Warning "ReleasesRoot was set to an IIS object path. Resetting to install-root releases path."
        $script:ReleasesRoot = Join-Path (Join-Path $installRoot "releases") $safeSiteName
    }

    if ($BackupPreviousPhysicalPathTo -match "^IIS:") {
        Write-Warning "BackupPreviousPhysicalPathTo was set to an IIS object path. Resetting to install-root backup path."
        $script:BackupPreviousPhysicalPathTo = Join-Path (Join-Path $installRoot "backups") $safeSiteName
    }

    if ($BackupPreviousPhysicalPathOnlyWhen -match "^IIS:") {
        Write-Warning "BackupPreviousPhysicalPathOnlyWhen was set to an IIS object path. Clearing guard path."
        $script:BackupPreviousPhysicalPathOnlyWhen = ""
    }

    if ($IisPath -match "^[A-Za-z]:[\\/]") {
        Write-Warning "IisPath was set to a disk path. Moving it to old website disk path and clearing IIS object path."
        $script:BackupPreviousPhysicalPathOnlyWhen = $IisPath
        $script:IisPath = ""
    }
}

function Ensure-IisManagementApi {
    try {
        Add-Type -AssemblyName "Microsoft.Web.Administration" -ErrorAction Stop
        return
    }
    catch {
        # Try file-based load below.
    }

    $candidatePaths = @(
        (Join-Path $env:windir "System32\inetsrv\Microsoft.Web.Administration.dll"),
        (Join-Path $env:windir "SysWOW64\inetsrv\Microsoft.Web.Administration.dll")
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            Add-Type -Path $candidatePath -ErrorAction Stop
            return
        }
    }

    if (-not $InstallMissingDependencies) {
        throw "IIS management API is missing. Install IIS Management Scripts and Tools."
    }

    Write-Host "Installing IIS Management Scripts and Tools for IIS API access."
    $serverManager = Get-Module -ListAvailable ServerManager
    if ($serverManager) {
        Import-Module ServerManager -ErrorAction Stop
        Install-WindowsFeature Web-Server, Web-Mgmt-Tools, Web-Scripting-Tools -IncludeManagementTools | Out-Host
    }
    else {
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementScriptingTools -All -NoRestart | Out-Host
    }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            Add-Type -Path $candidatePath -ErrorAction Stop
            return
        }
    }

    throw "IIS management API still missing after install attempt. Restart PowerShell/server, then run again."
}

function Resolve-IisApplicationSelector {
    param(
        [string]$ConfiguredSiteName,
        [string]$ConfiguredIisPath
    )

    $site = $ConfiguredSiteName
    $applicationPath = "/"

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredIisPath)) {
        $path = $ConfiguredIisPath.Trim()

        if ($path -match "^[A-Za-z]:[\\/]") {
            throw "'$ConfiguredIisPath' is a disk path. IIS object path should be blank, 'IIS:\Sites\<site>', or 'IIS:\Sites\<site>\<app>'."
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
        DisplayPath = if ($applicationPath -eq "/") { "IIS:\Sites\$site" } else { "IIS:\Sites\$site$($applicationPath -replace '/', '\')" }
    }
}

function Get-IisApplicationTarget {
    param(
        [string]$ConfiguredSiteName,
        [string]$ConfiguredIisPath
    )

    Ensure-IisManagementApi

    $selector = Resolve-IisApplicationSelector -ConfiguredSiteName $ConfiguredSiteName -ConfiguredIisPath $ConfiguredIisPath
    $manager = New-Object Microsoft.Web.Administration.ServerManager

    $site = $manager.Sites | Where-Object { $_.Name -eq $selector.SiteName } | Select-Object -First 1
    if (-not $site) {
        $knownSites = ($manager.Sites | ForEach-Object { $_.Name }) -join ", "
        throw "IIS site '$($selector.SiteName)' was not found. Existing sites: $knownSites"
    }

    $application = $site.Applications | Where-Object { $_.Path -eq $selector.ApplicationPath } | Select-Object -First 1
    if (-not $application) {
        $knownApps = ($site.Applications | ForEach-Object { $_.Path }) -join ", "
        throw "IIS application '$($selector.ApplicationPath)' was not found under site '$($selector.SiteName)'. Existing apps: $knownApps"
    }

    $virtualDirectory = $application.VirtualDirectories | Where-Object { $_.Path -eq "/" } | Select-Object -First 1
    if (-not $virtualDirectory) {
        throw "IIS application '$($selector.ApplicationPath)' does not have root virtual directory '/'."
    }

    return [pscustomobject]@{
        Manager = $manager
        Site = $site
        Application = $application
        VirtualDirectory = $virtualDirectory
        PhysicalPath = $virtualDirectory.PhysicalPath
        ApplicationPoolName = $application.ApplicationPoolName
        DisplayPath = $selector.DisplayPath
    }
}

function Get-IisItemPhysicalPath {
    param([string]$Path)

    $target = Get-IisApplicationTarget -ConfiguredSiteName $SiteName -ConfiguredIisPath $Path
    $physicalPath = $target.PhysicalPath

    if ([string]::IsNullOrWhiteSpace($physicalPath)) {
        return ""
    }

    return [Environment]::ExpandEnvironmentVariables($physicalPath)
}

function Get-IisItemAppPool {
    param([string]$Path)

    $target = Get-IisApplicationTarget -ConfiguredSiteName $SiteName -ConfiguredIisPath $Path
    $pool = $target.ApplicationPoolName

    if ([string]::IsNullOrWhiteSpace($pool)) {
        return ""
    }

    return $pool
}

function Set-IisItemPhysicalPath {
    param(
        [string]$Path,
        [string]$PhysicalPath
    )

    $target = Get-IisApplicationTarget -ConfiguredSiteName $SiteName -ConfiguredIisPath $Path
    $target.VirtualDirectory.PhysicalPath = $PhysicalPath
    $target.Manager.CommitChanges()
}

function Restart-IisApplicationPool {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    Ensure-IisManagementApi

    $manager = New-Object Microsoft.Web.Administration.ServerManager
    $pool = $manager.ApplicationPools | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $pool) {
        Write-Warning "App pool '$Name' was not found; restart skipped."
        return
    }

    try {
        if ($pool.State -eq [Microsoft.Web.Administration.ObjectState]::Started) {
            $pool.Recycle() | Out-Null
            Write-Host "Recycled app pool: $Name"
        }
        elseif ($pool.State -eq [Microsoft.Web.Administration.ObjectState]::Stopped) {
            $pool.Start() | Out-Null
            Write-Host "Started app pool: $Name"
        }
        else {
            Write-Host "App pool '$Name' is $($pool.State); waiting before restart."
            Start-Sleep -Seconds 3
            $pool.Recycle() | Out-Null
        }
    }
    catch {
        Write-Warning "App pool '$Name' restart/recycle failed: $($_.Exception.Message)"
    }
}

function Copy-PreservedFiles {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string[]]$RelativePaths
    )

    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or -not (Test-Path -LiteralPath $SourceRoot)) {
        return
    }

    foreach ($relativePath in $RelativePaths) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $sourcePath = Join-Path $SourceRoot $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            continue
        }

        $destinationPath = Join-Path $DestinationRoot $relativePath
        $destinationDir = Split-Path -Parent $destinationPath

        if (-not (Test-Path -LiteralPath $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        Write-Host "Preserved $relativePath"
    }
}

function Copy-ConfigOverlay {
    param(
        [string]$OverlayPath,
        [string]$DestinationRoot
    )

    if ([string]::IsNullOrWhiteSpace($OverlayPath)) {
        return
    }

    $resolvedOverlay = Resolve-Path -LiteralPath $OverlayPath -ErrorAction Stop
    Get-ChildItem -LiteralPath $resolvedOverlay.Path -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $DestinationRoot -Recurse -Force
    }

    Write-Host "Applied config overlay from $($resolvedOverlay.Path)"
}

function Move-PreviousPhysicalPathToBackup {
    param(
        [string]$PreviousPath,
        [string]$BackupPath,
        [string]$OnlyWhenPath,
        [string]$ActiveReleasePath,
        [switch]$Overwrite
    )

    if ([string]::IsNullOrWhiteSpace($BackupPath)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($PreviousPath) -or -not (Test-Path -LiteralPath $PreviousPath)) {
        Write-Warning "Previous IIS path does not exist, skipping backup move: $PreviousPath"
        return
    }

    $resolvedPrevious = (Resolve-Path -LiteralPath $PreviousPath).Path.TrimEnd("\")
    $resolvedActive = (Resolve-Path -LiteralPath $ActiveReleasePath).Path.TrimEnd("\")

    if (-not [string]::IsNullOrWhiteSpace($OnlyWhenPath)) {
        if (-not (Test-Path -LiteralPath $OnlyWhenPath)) {
            Write-Host "Backup source guard path does not exist; backup move skipped: $OnlyWhenPath"
            return
        }

        $resolvedOnlyWhen = (Resolve-Path -LiteralPath $OnlyWhenPath).Path.TrimEnd("\")
        if ($resolvedPrevious -ne $resolvedOnlyWhen) {
            Write-Host "Previous IIS path does not match backup source guard; backup move skipped."
            Write-Host "Previous path: $resolvedPrevious"
            Write-Host "Guard path: $resolvedOnlyWhen"
            return
        }
    }

    if ($resolvedPrevious -eq $resolvedActive) {
        Write-Host "Previous IIS path already equals active release; backup move skipped."
        return
    }

    $backupParent = Split-Path -Parent $BackupPath
    if (-not (Test-Path -LiteralPath $backupParent)) {
        New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
    }

    $finalBackupPath = $BackupPath
    if (Test-Path -LiteralPath $finalBackupPath) {
        if ($Overwrite) {
            Remove-Item -LiteralPath $finalBackupPath -Recurse -Force
        }
        else {
            $suffix = Get-Date -Format "yyyyMMdd-HHmmss"
            $finalBackupPath = "$BackupPath-$suffix"
        }
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Move-Item -LiteralPath $resolvedPrevious -Destination $finalBackupPath -ErrorAction Stop
            Write-Host "Moved previous IIS path to backup: $finalBackupPath"
            return
        }
        catch {
            if ($attempt -lt 5) {
                Write-Warning "Backup move attempt $attempt failed: $($_.Exception.Message). Retrying in 3 seconds."
                Start-Sleep -Seconds 3
                continue
            }

            Write-Warning "Could not move previous IIS path because files are still locked: $($_.Exception.Message)"
        }
    }

    $robocopy = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if ($robocopy) {
        Write-Warning "Copying previous IIS path to backup instead. Old folder will be left in place."

        & $robocopy.Source $resolvedPrevious $finalBackupPath /MIR /R:2 /W:2 /NFL /NDL /NJH /NJS /NP
        $exitCode = $LASTEXITCODE

        if ($exitCode -le 7) {
            Write-Host "Copied previous IIS path to backup: $finalBackupPath"
            return
        }

        Write-Warning "robocopy backup failed with exit code $exitCode. Deploy remains active; old folder left in place."
        return
    }

    Write-Warning "robocopy.exe was not found. Deploy remains active; old folder left in place."
}

function Test-TrackedGitClean {
    param(
        [string]$GitCommand,
        [string]$RootPath
    )

    & $GitCommand -C $RootPath diff --quiet --
    $workingTreeExitCode = $LASTEXITCODE
    & $GitCommand -C $RootPath diff --cached --quiet --
    $indexExitCode = $LASTEXITCODE

    if ($workingTreeExitCode -eq 1 -or $indexExitCode -eq 1) {
        return $false
    }

    if ($workingTreeExitCode -gt 1 -or $indexExitCode -gt 1) {
        throw "Could not check Git working tree status."
    }

    return $true
}

function Reset-TrackedGitChanges {
    param(
        [string]$GitCommand,
        [string]$RootPath
    )

    Write-Warning "Tracked local changes found in deployment checkout. Resetting tracked files before pull."
    Invoke-External -FilePath $GitCommand -Arguments @("-C", $RootPath, "reset", "--hard", "HEAD") -WorkingDirectory $RootPath
}

function Set-DeploymentGitConfig {
    param(
        [string]$GitCommand,
        [string]$RootPath
    )

    Invoke-External -FilePath $GitCommand -Arguments @("-C", $RootPath, "config", "core.autocrlf", "false") -WorkingDirectory $RootPath
    Invoke-External -FilePath $GitCommand -Arguments @("-C", $RootPath, "config", "core.filemode", "false") -WorkingDirectory $RootPath
}

function Initialize-GitRepository {
    param(
        [string]$GitCommand,
        [string]$RootPath,
        [string]$RepositoryUrl
    )

    if (Test-Path -LiteralPath (Join-Path $RootPath ".git") -PathType Container) {
        return
    }

    if (Test-Path -LiteralPath $RootPath) {
        $children = @(Get-ChildItem -LiteralPath $RootPath -Force -ErrorAction Stop)
        if ($children.Count -gt 0) {
            throw "Repo path exists but is not a Git repository: $RootPath"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) {
        throw "Repo path does not exist and GitHubRepositoryUrl was not provided: $RootPath"
    }

    $repoParent = Split-Path -Parent $RootPath
    if (-not (Test-Path -LiteralPath $repoParent)) {
        New-Item -ItemType Directory -Path $repoParent -Force | Out-Null
    }

    Write-Host "Cloning repository into $RootPath"
    Invoke-External -FilePath $GitCommand -Arguments @("clone", $RepositoryUrl, $RootPath) -WorkingDirectory $repoParent
}

function Get-FileSha256 {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ""
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-NpmInstallRequired {
    param(
        [string]$RootPath,
        [string]$CacheRoot,
        [switch]$Force
    )

    if ($Force) {
        return $true
    }

    $nodeModulesPath = Join-Path $RootPath "node_modules"
    if (-not (Test-Path -LiteralPath $nodeModulesPath -PathType Container)) {
        return $true
    }

    $packageLockPath = Join-Path $RootPath "package-lock.json"
    if (-not (Test-Path -LiteralPath $packageLockPath -PathType Leaf)) {
        return $true
    }

    $cacheFile = Join-Path $CacheRoot "package-lock.sha256"
    if (-not (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
        return $true
    }

    $currentHash = Get-FileSha256 -Path $packageLockPath
    $cachedHash = (Get-Content -LiteralPath $cacheFile -Raw).Trim()

    return $currentHash -ne $cachedHash
}

function Save-NpmInstallState {
    param(
        [string]$RootPath,
        [string]$CacheRoot
    )

    $packageLockPath = Join-Path $RootPath "package-lock.json"
    if (-not (Test-Path -LiteralPath $packageLockPath -PathType Leaf)) {
        return
    }

    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
    }

    $cacheFile = Join-Path $CacheRoot "package-lock.sha256"
    Get-FileSha256 -Path $packageLockPath | Set-Content -LiteralPath $cacheFile -Encoding ASCII
}

function Update-BrowserslistDatabase {
    param(
        [string]$NpmCommand,
        [string]$RootPath
    )

    if ($SkipBrowserslistUpdate) {
        return
    }

    $packageJsonPath = Join-Path $RootPath "package.json"
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        return
    }

    Write-Step "Updating Browserslist database"

    try {
        Invoke-External -FilePath $NpmCommand -Arguments @("exec", "--yes", "update-browserslist-db@latest") -WorkingDirectory $RootPath
    }
    catch {
        Write-Warning "Browserslist database update failed but deploy will continue: $($_.Exception.Message)"
    }
}

function Test-NpmScript {
    param(
        [string]$RootPath,
        [string]$ScriptName
    )

    $packageJsonPath = Join-Path $RootPath "package.json"
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        return $false
    }

    try {
        $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read package.json at '$packageJsonPath': $($_.Exception.Message)"
    }

    if (-not $packageJson.PSObject.Properties["scripts"]) {
        return $false
    }

    return $null -ne $packageJson.scripts.PSObject.Properties[$ScriptName]
}

function Show-IISForgeEngineUsageAndExit {
    $installRoot = Get-IISForgeInstallRoot
    $wizardPath = Join-Path $installRoot "new-iis-forge-profile.ps1"

    Write-Host ""
    Write-Host "IIS Forge engine was started without an IIS site/profile." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Recommended first-time flow:"
    Write-Host "  cd `"<IISForgeRoot>`""
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$wizardPath`""
    Write-Host ""
    Write-Host "After the wizard creates a launcher, deploy with:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"<IISForgeRoot>\<profile>.deploy.ps1`""
    Write-Host ""
    Write-Host "Advanced direct engine usage example:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -SiteName `"example.com`" -GitHubRepositoryUrl `"https://github.com/owner/repo.git`""
    Write-Host ""
    exit 2
}

trap {
    Complete-DeployProgress
    Write-Host ""
    Write-Host "Deployment failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) {
        Write-Host "At: $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
        Write-Host "$($_.InvocationInfo.Line)" -ForegroundColor DarkRed
    }
    exit 1
}

if ([string]::IsNullOrWhiteSpace($SiteName) -and [string]::IsNullOrWhiteSpace($IisPath)) {
    Show-IISForgeEngineUsageAndExit
}

Assert-Administrator
Repair-AccidentalIisPathInputs

$git = Ensure-Command -Name "git" -PackageId "Git.Git" -DisplayName "Git"
$installRoot = Get-IISForgeInstallRoot
$safeSiteName = Get-IISForgeSafeName -Value $SiteName

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    $RepoPath = Join-Path (Join-Path $installRoot "repos") $safeSiteName
}

$RepoPath = Resolve-IISForgePath -Path $RepoPath -BasePath $installRoot
Initialize-GitRepository -GitCommand $git -RootPath $RepoPath -RepositoryUrl $GitHubRepositoryUrl
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path

if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = Resolve-SingleProject -RootPath $RepoPath
}
elseif (-not [IO.Path]::IsPathRooted($ProjectPath)) {
    $ProjectPath = Join-Path $RepoPath $ProjectPath
}
if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
}

if ([string]::IsNullOrWhiteSpace($SolutionPath)) {
    $SolutionPath = Resolve-OptionalSolution -RootPath $RepoPath
}
elseif (-not [IO.Path]::IsPathRooted($SolutionPath)) {
    $SolutionPath = Join-Path $RepoPath $SolutionPath
}
if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
    $SolutionPath = (Resolve-Path -LiteralPath $SolutionPath).Path
}

if ([string]::IsNullOrWhiteSpace($ReleasesRoot)) {
    $ReleasesRoot = Join-Path (Join-Path $installRoot "releases") $safeSiteName
}
$ReleasesRoot = Resolve-IISForgePath -Path $ReleasesRoot -BasePath $installRoot
$ConfigOverlayPath = Resolve-IISForgePath -Path $ConfigOverlayPath -BasePath $installRoot
$BackupPreviousPhysicalPathTo = Resolve-IISForgePath -Path $BackupPreviousPhysicalPathTo -BasePath $installRoot
$BackupPreviousPhysicalPathOnlyWhen = Resolve-IISForgePath -Path $BackupPreviousPhysicalPathOnlyWhen -BasePath $installRoot

$dotNetMajor = 0
$dotnet = ""
$dotnetWorkingDirectory = $RepoPath
if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    $dotNetMajor = Resolve-DotNetMajor -ProjectFile $ProjectPath -RootPath $RepoPath
    $dotnet = Ensure-Command -Name "dotnet" -PackageId "Microsoft.DotNet.SDK.$dotNetMajor" -DisplayName ".NET $dotNetMajor SDK"
    $dotnet = Ensure-DotNetSdkMajor -DotNetCommand $dotnet -Major $dotNetMajor
    $dotnetWorkingDirectory = Initialize-DotNetSdkSelection -RootPath $RepoPath -Major $dotNetMajor
}

$npm = ""
if (-not $SkipNpmInstall -or -not $SkipNpmBuild) {
    $npm = Ensure-Command -Name "npm.cmd" -PackageId "OpenJS.NodeJS.LTS" -DisplayName "Node.js LTS"
}

Ensure-IisManagementApi
if (-not [string]::IsNullOrWhiteSpace($dotnet)) {
    Ensure-AspNetCoreHostingBundle -DotNetCommand $dotnet -Major $dotNetMajor
}

$previousPhysicalPath = Get-IisItemPhysicalPath -Path $IisPath
if ([string]::IsNullOrWhiteSpace($previousPhysicalPath)) {
    throw "Could not read physicalPath from IIS item '$IisPath'."
}

if ([string]::IsNullOrWhiteSpace($AppPoolName)) {
    $AppPoolName = Get-IisItemAppPool -Path $IisPath
}

Write-Host "Repo: $RepoPath"
if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
    Write-Host "Project: $ProjectPath"
}
else {
    Write-Host "Project: static/site files"
}
Write-Host "IIS item: $IisPath"
Write-Host "Current IIS path: $previousPhysicalPath"
Write-Host "Releases root: $ReleasesRoot"
if (-not [string]::IsNullOrWhiteSpace($AppPoolName)) {
    Write-Host "App pool: $AppPoolName"
}
if ($dotNetMajor -gt 0) {
    Write-Host ".NET SDK target: $dotNetMajor.x"
}

if (-not $SkipGitPull) {
    Write-Step "Checking GitHub remote"
    Set-DeploymentGitConfig -GitCommand $git -RootPath $RepoPath
    $remoteUrl = Get-GitRemoteUrl -GitCommand $git -RootPath $RepoPath -RemoteName $Remote
    Test-GitHubRemote -RemoteUrl $remoteUrl -ExpectedUrl $GitHubRepositoryUrl
    Write-Host "GitHub remote: $remoteUrl"

    Write-Step "Pulling latest GitHub branch '$Branch'"

    $beforeCommit = (& $git -C $RepoPath rev-parse --short HEAD).Trim()
    Write-Host "Current commit: $beforeCommit"

    if (-not $AllowDirty) {
        $isClean = Test-TrackedGitClean -GitCommand $git -RootPath $RepoPath
        if (-not $isClean) {
            if ($DiscardLocalChanges) {
                Reset-TrackedGitChanges -GitCommand $git -RootPath $RepoPath
            }
            else {
                throw "Tracked local changes exist in '$RepoPath'. Commit/stash them, pass -AllowDirty, or pass -DiscardLocalChanges for a managed deployment checkout."
            }
        }
    }

    Invoke-External -FilePath $git -Arguments @("-C", $RepoPath, "fetch", "--prune", $Remote) -WorkingDirectory $RepoPath

    & $git -C $RepoPath rev-parse --verify "$Remote/$Branch" *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Remote branch '$Remote/$Branch' was not found."
    }

    $currentBranch = (& $git -C $RepoPath branch --show-current).Trim()
    if ($currentBranch -ne $Branch) {
        $localBranches = & $git -C $RepoPath for-each-ref "--format=%(refname:short)" refs/heads
        if ($localBranches -contains $Branch) {
            Invoke-External -FilePath $git -Arguments @("-C", $RepoPath, "switch", $Branch) -WorkingDirectory $RepoPath
        }
        else {
            Invoke-External -FilePath $git -Arguments @("-C", $RepoPath, "switch", "--track", "-c", $Branch, "$Remote/$Branch") -WorkingDirectory $RepoPath
        }
    }

    Invoke-External -FilePath $git -Arguments @("-C", $RepoPath, "pull", "--ff-only", $Remote, $Branch) -WorkingDirectory $RepoPath

    $afterCommit = (& $git -C $RepoPath rev-parse --short HEAD).Trim()
    Write-Host "Pulled commit: $afterCommit"
}
else {
    Write-Step "Skipping GitHub pull"
}

$commit = (& $git -C $RepoPath rev-parse --short HEAD).Trim()
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$releaseName = "$timestamp-$commit"
$stagingRoot = Join-Path $ReleasesRoot "_staging"
$stagingPath = Join-Path $stagingRoot $releaseName
$releasePath = Join-Path $ReleasesRoot $releaseName

try {
    Write-Step "Preparing release staging folder"

    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
    New-Item -ItemType Directory -Path $ReleasesRoot -Force | Out-Null

    $packageJsonPath = Join-Path $RepoPath "package.json"
    if (Test-Path -LiteralPath $packageJsonPath) {
        if (-not $SkipNpmInstall) {
            $npmCacheRoot = Join-Path (Join-Path $PSScriptRoot ".cache") "npm"
            $needsNpmInstall = Test-NpmInstallRequired -RootPath $RepoPath -CacheRoot $npmCacheRoot -Force:$ForceNpmInstall

            if ($needsNpmInstall) {
                Write-Step "Installing Node packages"
                if (Test-Path -LiteralPath (Join-Path $RepoPath "package-lock.json")) {
                    Invoke-External -FilePath $npm -Arguments @("ci") -WorkingDirectory $RepoPath
                }
                else {
                    Invoke-External -FilePath $npm -Arguments @("install") -WorkingDirectory $RepoPath
                }

                Save-NpmInstallState -RootPath $RepoPath -CacheRoot $npmCacheRoot
            }
            else {
                Write-Step "Skipping Node package install; lockfile unchanged"
            }
        }

        if (-not $SkipNpmBuild) {
            if (-not (Test-NpmScript -RootPath $RepoPath -ScriptName "build")) {
                Write-Step "Skipping Node build; package.json has no build script"
            }
            else {
                Update-BrowserslistDatabase -NpmCommand $npm -RootPath $RepoPath

                Write-Step "Building static assets"
                Invoke-External -FilePath $npm -Arguments @("run", "build") -WorkingDirectory $RepoPath
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
        $restoreTarget = $ProjectPath
        if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
            $restoreTarget = $SolutionPath
        }

        Write-Step "Restoring .NET packages"
        Invoke-External -FilePath $dotnet -Arguments @("restore", $restoreTarget) -WorkingDirectory $dotnetWorkingDirectory

        if (-not [string]::IsNullOrWhiteSpace($RuntimeIdentifier)) {
            Write-Step "Restoring .NET packages for runtime '$RuntimeIdentifier'"
            Invoke-External -FilePath $dotnet -Arguments @("restore", $ProjectPath, "--runtime", $RuntimeIdentifier) -WorkingDirectory $dotnetWorkingDirectory
        }

        if ($RunTests) {
            if ([string]::IsNullOrWhiteSpace($SolutionPath)) {
                throw "RunTests was requested, but no .sln file was found. Pass -SolutionPath explicitly."
            }

            Write-Step "Running tests"
            Invoke-External -FilePath $dotnet -Arguments @("test", $SolutionPath, "--configuration", $Configuration, "--no-restore") -WorkingDirectory $dotnetWorkingDirectory
        }

        Write-Step "Publishing ASP.NET Core app"
        $publishArgs = @(
            "publish",
            $ProjectPath,
            "--configuration",
            $Configuration,
            "--no-restore",
            "--output",
            $stagingPath
        )

        if (-not [string]::IsNullOrWhiteSpace($RuntimeIdentifier)) {
            $publishArgs += @("--runtime", $RuntimeIdentifier)
        }

        $publishArgs += @("--self-contained", $SelfContained.ToString().ToLowerInvariant())
        Invoke-External -FilePath $dotnet -Arguments $publishArgs -WorkingDirectory $dotnetWorkingDirectory
    }
    else {
        Write-Step "Copying static publish output"
        $staticRoot = Resolve-StaticPublishRoot -RootPath $RepoPath -PublishPath $StaticPublishPath
        Write-Host "Static publish root: $staticRoot"
        Copy-DirectoryContents -SourceRoot $staticRoot -DestinationRoot $stagingPath
    }

    Copy-PreservedFiles -SourceRoot $previousPhysicalPath -DestinationRoot $stagingPath -RelativePaths $PreserveFiles
    Copy-ConfigOverlay -OverlayPath $ConfigOverlayPath -DestinationRoot $stagingPath

    $deploymentMetadata = [ordered]@{
        deployedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        repoPath = $RepoPath
        remote = $Remote
        branch = $Branch
        commit = (& $git -C $RepoPath rev-parse HEAD).Trim()
        configuration = $Configuration
        runtimeIdentifier = $RuntimeIdentifier
        selfContained = $SelfContained
        projectPath = $ProjectPath
        staticPublishPath = $StaticPublishPath
    }

    $deploymentMetadata |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $stagingPath "deployment.json") -Encoding UTF8

    Move-Item -LiteralPath $stagingPath -Destination $releasePath
}
finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}

Write-Step "Switching IIS to $releasePath"
Set-IisItemPhysicalPath -Path $IisPath -PhysicalPath $releasePath

if (-not [string]::IsNullOrWhiteSpace($AppPoolName)) {
    Restart-IisApplicationPool -Name $AppPoolName
}

if ($KeepReleases -gt 0) {
    Write-Step "Removing old releases"
    $activePath = (Resolve-Path -LiteralPath $releasePath).Path
    Get-ChildItem -LiteralPath $ReleasesRoot -Directory |
        Where-Object { $_.Name -ne "_staging" } |
        Where-Object { (Resolve-Path -LiteralPath $_.FullName).Path -ne $activePath } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip ([Math]::Max(0, $KeepReleases - 1)) |
        ForEach-Object {
            Write-Host "Removing $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force
        }
}

if (-not [string]::IsNullOrWhiteSpace($BackupPreviousPhysicalPathTo)) {
    Write-Step "Backing up previous IIS path"
    Move-PreviousPhysicalPathToBackup `
        -PreviousPath $previousPhysicalPath `
        -BackupPath $BackupPreviousPhysicalPathTo `
        -OnlyWhenPath $BackupPreviousPhysicalPathOnlyWhen `
        -ActiveReleasePath $releasePath `
        -Overwrite:$OverwritePreviousPhysicalPathBackup
}

Write-Host ""
Write-Host "Deployment complete."
Write-Host "Active release: $releasePath"
Write-Host "Commit: $commit"
Write-Host "Elapsed: $(Format-Elapsed -Elapsed ((Get-Date) - $script:DeploymentStartedAt))"
Complete-DeployProgress
