# Troubleshooting

## Files Are Not in the Old IIS Folder

That is expected after a successful IIS Forge deploy.

Before deploy, IIS may serve a folder like:

```text
<SiteContentRoot>\clockhorizon
```

After deploy, IIS Forge switches IIS to a release folder like:

```text
<IISForgeRoot>\releases\clockhorizon\<timestamp>
```

Do not set `StaticPublishPath` to the old IIS folder. `StaticPublishPath` is only for a folder inside the Git repo, and for ASP.NET Core apps it should usually stay blank.

## It Asked for `SiteName` and Then Closed

That means the shared engine was run directly instead of the profile wizard or a generated launcher.

Use this first:

```powershell
powershell -ExecutionPolicy Bypass -File <IISForgeRoot>\new-iis-forge-profile.ps1
```

Then deploy with the generated launcher:

```powershell
powershell -ExecutionPolicy Bypass -File <IISForgeRoot>\<profile>.deploy.ps1
```

Current versions of IIS Forge print this guidance instead of showing PowerShell's raw mandatory-parameter prompt.

## `IIS Forge engine not found` from a `scripts\iis-forge.ps1` path

That means an older generated launcher is looking for the legacy `scripts\` layout. Current launchers prefer the flat install root.

Correct flow:

```powershell
cd <IISForgeRoot>
powershell -ExecutionPolicy Bypass -File .\<profile>.deploy.ps1
```

If the launcher was generated before this fix, regenerate it once:

```powershell
cd <IISForgeRoot>
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName <profile> -Configure
```

New launchers resolve the profile and shared engine from the launcher folder without embedding a machine-specific install path.

## `IIS Forge engine not found. Expected <IISForgeRoot>\iis-forge.ps1`

The profile and launcher exist, but the shared engine file is missing.

Current versions of the wizard restore the engine automatically when possible. To fix an existing install manually:

```powershell
cd <IISForgeRoot>
Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/sduddupudi/IIS-Forge/main/iis-forge.ps1 -OutFile .\iis-forge.ps1
Invoke-WebRequest -UseBasicParsing -Uri https://raw.githubusercontent.com/sduddupudi/IIS-Forge/main/new-iis-forge-profile.ps1 -OutFile .\new-iis-forge-profile.ps1
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName <profile> -Configure
```

Then deploy:

```powershell
powershell -ExecutionPolicy Bypass -File .\<profile>.deploy.ps1
```

## Launcher Was Created at a Drive Root

The wizard used a drive root as the install root. Current versions block this and ask for a real install folder.

Regenerate the launcher and explicitly pass your install folder:

```powershell
cd <IISForgeRoot>
git pull
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName <profile> -Configure
```

The launcher should then be created at:

```text
<IISForgeRoot>\<profile>.deploy.ps1
```

If a wrong launcher exists at a drive root, remove it.

## Git Is Missing

Enable `InstallMissingDependencies`, or install Git manually. If `winget` is unavailable, IIS Forge downloads Git for Windows from GitHub releases.

## GitHub Login

IIS Forge uses normal Git authentication.

For HTTPS private repos, sign in once with Git Credential Manager:

```powershell
git ls-remote https://github.com/OWNER/REPO.git
```

For SSH repos, make sure the service account has the SSH key and known host entry.

## Build Uses Wrong .NET SDK

IIS Forge writes a temporary `global.json` under `.cache\dotnet-sdk\net<major>` and runs dotnet from there. If a preview SDK is being selected, confirm the profile is using the latest `scripts\iis-forge.ps1`.

## npm Install Runs Too Often

IIS Forge stores a package-lock hash in `.cache\npm`. It skips install when `node_modules` exists and the lockfile hash did not change.

Use this to force install:

```powershell
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1 -ForceNpmInstall
```

## Console Hangs Until Enter

This is often Windows console QuickEdit selection pause. IIS Forge disables QuickEdit by default.

## Locked Old Folder

If the previous IIS path is locked during backup, IIS Forge retries. If move still fails, it uses `robocopy /MIR` to copy backup and leaves the old folder in place.

## IIS Object Path vs Disk Path

IIS object path:

```text
IIS:\Sites\example.com
```

Disk path:

```text
<SiteContentRoot>\example.com
```

Do not put a disk path in `IisPath`. Use disk paths for `ReleasesRoot`, `RepoPath`, backup paths, and config overlay paths.

## No .csproj Found

For static sites, set `StaticPublishPath` to the folder that IIS should serve:

```json
"StaticPublishPath": "dist"
```

For ASP.NET Core solutions with multiple projects, set `ProjectPath` explicitly.
