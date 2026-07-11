# Operations Runbook

This runbook is for server operators deploying sites with IIS Forge.

## Normal Deploy

```powershell
cd <IISForgeRoot>
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1
```

## Deploy a Different Branch

```powershell
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1 -Branch staging
```

## Force Node Package Install

```powershell
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1 -ForceNpmInstall
```

## Skip Frontend Build

Use only when the repo already contains final static assets.

```powershell
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1 -SkipNpmInstall -SkipNpmBuild
```

## Run Tests Before Publish

```powershell
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1 -RunTests
```

## Manual Rollback

1. Open IIS Manager.
2. Select the site/application.
3. Change physical path to a previous release under `ReleasesRoot`.
4. Recycle the app pool.

PowerShell:

```powershell
Import-Module WebAdministration
Set-ItemProperty "IIS:\Sites\example.com" -Name physicalPath -Value "<IISForgeRoot>\releases\example.com\20260707-101500-a1b2c3d"
Restart-WebAppPool -Name "example.com"
```

## Update IIS Forge Engine

```powershell
cd <IISForgeRoot>
git pull
```

Generated site launchers continue to call the shared engine.

## Add Another IIS Site

```powershell
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName api.example.com
```

Then deploy:

```powershell
powershell -ExecutionPolicy Bypass -File .\api.example.com.deploy.ps1
```

## Backup Policy

IIS Forge keeps recent release folders based on `KeepReleases`.

For long-term retention, back up:

- `profiles\`
- production overlay folders
- release folders required by your retention policy
- application data outside the release folder

Do not rely on release folders as your only backup.
