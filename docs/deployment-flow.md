# Deployment Flow

IIS Forge performs a release-folder deployment.

## Steps

1. Disable console QuickEdit mode so the prompt cannot pause by accidental mouse selection.
2. Ensure required commands and IIS management APIs are available.
3. Clone the repository if `RepoPath` does not exist.
4. Configure Git checkout behavior for deployment.
5. Fetch and fast-forward pull the target branch.
6. Reset tracked local changes when `DiscardLocalChanges` is enabled.
7. Create a staging folder under `ReleasesRoot\_staging`.
8. If `package.json` exists, install Node packages when needed.
9. If `package.json` exists, run `npm run build` unless skipped.
10. If a `.csproj` exists, restore and publish with dotnet.
11. If no `.csproj` exists, copy static output from `StaticPublishPath` or detected output folder.
12. Copy preserved files from the previous IIS path.
13. Copy secure config overlay.
14. Write `deployment.json`.
15. Move staging folder to a timestamped release folder.
16. Switch IIS physical path to the new release.
17. Recycle the app pool.
18. Remove old releases according to `KeepReleases`.
19. Optionally back up the previous physical path.

## No Health Check

IIS Forge does not call `/health` or any URL after deployment. The universal engine should not know application-specific HTTP behavior. It compiles, publishes, replaces the IIS path, and recycles the app pool.

## .NET Version Selection

IIS Forge detects the target .NET major version from:

1. `.csproj` `TargetFramework` / `TargetFrameworks`
2. `global.json` `sdk.version`

It then uses:

```text
Microsoft.DotNet.SDK.<major>
Microsoft.DotNet.HostingBundle.<major>
```

If `winget` is unavailable, fallback downloads use the detected major:

```text
dotnet-install.ps1 -Channel <major>.0
https://aka.ms/dotnet/<major>.0/dotnet-hosting-win.exe
```

This lets future .NET versions work without changing IIS Forge code, as long as Microsoft keeps the package and download naming pattern.

## Rollback

Manual rollback is folder-based:

1. Open IIS Manager.
2. Select the site/application.
3. Change physical path to a previous folder under `ReleasesRoot`.
4. Recycle the app pool.

PowerShell example:

```powershell
Import-Module WebAdministration
Set-ItemProperty "IIS:\Sites\example.com" -Name physicalPath -Value "<IISForgeRoot>\releases\example.com\previous-release"
Restart-WebAppPool -Name "example.com"
```
