# Architecture

IIS Forge has three layers:

1. Shared engine
2. JSON profiles
3. Generated launchers

This keeps multi-site IIS deployments manageable. You update the engine once, while each site keeps its own profile.

## Components

```text
iis-forge.ps1
```

The deployment engine. It performs dependency checks, Git operations, build/publish work, release creation, IIS switching, app pool recycle, cleanup, and backup.

```text
new-iis-forge-profile.ps1
```

The profile wizard. It asks first-run questions and writes one JSON profile plus one tiny launcher per site.

```text
profiles\<profile>.json
```

Data-only configuration for one IIS site/application.

```text
<profile>.deploy.ps1
```

A generated launcher that loads the profile and calls the shared engine.

## Deployment Model

IIS Forge uses immutable-ish release folders:

```text
releases\example.com\
  _staging\
  20260707-101500-a1b2c3d\
  20260707-113000-e4f5a6b\
```

The active IIS site points to one release folder at a time. New deployments publish into `_staging`, move the completed folder into place, then update IIS.

This avoids in-place file replacement and reduces locked-file issues.

## Design Principles

- One engine supports many IIS sites.
- Profiles are declarative JSON.
- Launchers stay tiny and disposable.
- Builds happen on the IIS server from a Git checkout.
- App-specific HTTP checks are not part of the engine.
- .NET version selection comes from the app, not from hardcoded script values.
- Production secrets stay outside Git.

## IIS Integration

IIS Forge uses `Microsoft.Web.Administration.ServerManager` for core IIS operations. This avoids relying only on the `IIS:\` PowerShell drive, which can be unavailable in some PowerShell sessions.

The engine can still install/enable IIS management tooling when dependency installation is allowed.

## Dependency Strategy

IIS Forge first checks whether a dependency exists. It installs only when required and when `InstallMissingDependencies` is enabled.

Preferred installer:

```text
winget
```

Fallback installers:

- Git for Windows from GitHub releases
- Node.js LTS MSI from nodejs.org
- .NET SDK using `dotnet-install.ps1`
- ASP.NET Core Hosting Bundle from `aka.ms`

## Future .NET Versions

The engine composes package IDs and download channels from the detected target major:

```text
Microsoft.DotNet.SDK.<major>
Microsoft.DotNet.HostingBundle.<major>
dotnet-install.ps1 -Channel <major>.0
https://aka.ms/dotnet/<major>.0/dotnet-hosting-win.exe
```

If Microsoft keeps these patterns, new .NET majors do not require IIS Forge code changes.
