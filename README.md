# IIS Forge

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20IIS-0078D4)](https://www.iis.net/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

IIS Forge is a production-oriented PowerShell deployment toolkit for IIS. It replaces manual Visual Studio publish and hand-copied folders with a repeatable release-folder deployment flow that works across many IIS sites on the same server.

It is designed for teams that want a simple server-side deploy command without adopting a full CI/CD platform on day one.

```powershell
powershell -ExecutionPolicy Bypass -File <IISForgeRoot>\example.com.deploy.ps1
```

## What It Does

IIS Forge deploys by building into a new timestamped release folder and then switching IIS to that folder.

IIS Forge does not keep serving files from the old IIS folder such as `<SiteContentRoot>\clockhorizon`.
On first deploy, it reads that current IIS website folder, publishes the app into
`<IISForgeRoot>\releases\<profile>\<timestamp>`, and changes IIS to serve that release folder.

| Area | Behavior |
| --- | --- |
| Git | Clone missing repo, fetch, fast-forward pull, optional dirty-check reset |
| Dependencies | Bootstrap Git, Node.js, .NET SDK, ASP.NET Core Hosting Bundle, and IIS management tooling |
| .NET | Detect target framework major from `.csproj` or `global.json`, install/pin matching SDK |
| Node/static assets | Run `npm ci`/`npm install` and `npm run build` when `package.json` exists |
| ASP.NET Core | `dotnet restore`, runtime restore, and `dotnet publish` |
| Static sites | Deploy `dist`, `build`, `public`, `wwwroot`, `out`, or configured static output |
| IIS | Switch site/application physical path and recycle app pool |
| Config | Preserve production files and copy secure overlay folders |
| Releases | Keep latest releases and support manual folder rollback |

IIS Forge intentionally does **not** run HTTP health checks. It compiles, publishes, replaces the IIS physical path, and recycles the app pool. App-specific smoke tests belong outside the universal engine.

## Why IIS Forge

Manual IIS deployments become fragile when:

- one server hosts many websites
- Git, Node.js, .NET SDK, or Hosting Bundle are missing
- a preview .NET SDK accidentally hijacks production builds
- locked files break manual folder replacement
- production config must survive each deploy
- deploy steps live in one person's memory
- rollback means guessing which folder was previously active

IIS Forge keeps one shared engine and generates one small profile/launcher per IIS site.

## Recommended Layout

Use any install root you want. IIS Forge keeps generated files and working folders inside that root by default.

```text
<IISForgeRoot>\
  iis-forge.ps1
  new-iis-forge-profile.ps1

  profiles\
    example.com.json
    api.example.com.json

  example.com.deploy.ps1
  api.example.com.deploy.ps1

  repos\
    example.com\
    api.example.com\

  releases\
    example.com\
    api.example.com\

  backups\
    example.com\
```

For 20 IIS sites, create 20 profiles and 20 small launchers. They all use the same `iis-forge.ps1` engine, so engine improvements are applied once.

## Quick Start

Clone IIS Forge onto the IIS server:

```powershell
git clone https://github.com/sduddupudi/IIS-Forge.git <IISForgeRoot>
cd <IISForgeRoot>
```

`<IISForgeRoot>` is the folder you choose for IIS Forge. Generated profiles use relative defaults, so repos, releases, and backups resolve under that folder at deploy time unless you explicitly enter absolute paths.

Create a site profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1
```

Deploy:

```powershell
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1
```

Do not start with `iis-forge.ps1` directly unless you are passing all engine parameters yourself. That file is the shared engine used by generated launchers. If it is run without a site/profile, it prints the wizard command and exits.

Keep generated launchers in the IIS Forge install folder. New launchers resolve the profile and shared engine from the launcher folder, so they do not need a stored install-root literal.

Reconfigure a profile:

```powershell
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName example.com -Configure
```

Deploy another branch once:

```powershell
powershell -ExecutionPolicy Bypass -File .\example.com.deploy.ps1 -Branch staging
```

## Supported Deployment Targets

### ASP.NET Core

- Auto-detects a single deployable `.csproj`, or uses `ProjectPath`.
- Reads `TargetFramework` / `TargetFrameworks`.
- Installs and pins the matching .NET SDK major.
- Installs the matching ASP.NET Core Hosting Bundle major.
- Runs `dotnet restore` and `dotnet publish`.

### Static or Node-built Sites

- If no `.csproj` exists, IIS Forge deploys static output.
- Use `StaticPublishPath`, or let IIS Forge auto-detect `dist`, `build`, `public`, `wwwroot`, or `out`.
- If `package.json` exists, IIS Forge can run `npm ci` / `npm install` and `npm run build`.

## .NET Version Handling

IIS Forge does not hardcode a .NET version.

It resolves the .NET major version from:

1. `.csproj` `TargetFramework` / `TargetFrameworks`
2. `global.json` `sdk.version`

Examples:

```text
net8.0  -> Microsoft.DotNet.SDK.8  + Microsoft.DotNet.HostingBundle.8
net9.0  -> Microsoft.DotNet.SDK.9  + Microsoft.DotNet.HostingBundle.9
net10.0 -> Microsoft.DotNet.SDK.10 + Microsoft.DotNet.HostingBundle.10
net11.0 -> Microsoft.DotNet.SDK.11 + Microsoft.DotNet.HostingBundle.11
```

It writes a local `global.json` under `.cache\dotnet-sdk\net<major>` to pin the selected SDK major, so a globally installed preview SDK cannot silently take over the build.

## Dependency Bootstrapping

With `InstallMissingDependencies = true`, IIS Forge can install:

- Git
- Node.js LTS
- .NET SDK matching the project target framework
- ASP.NET Core Hosting Bundle matching the project target framework
- IIS management tooling

It prefers `winget`. If `winget` is unavailable, it uses direct official download flows for Git, Node.js, .NET SDK, and Hosting Bundle.

## Documentation

- [Installation](docs/installation.md)
- [Architecture](docs/architecture.md)
- [Profiles](docs/profiles.md)
- [Configuration Reference](docs/configuration-reference.md)
- [Deployment Flow](docs/deployment-flow.md)
- [Operations Runbook](docs/operations-runbook.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security](docs/security.md)
- [Versioning](docs/versioning.md)

## Validation

Run parser validation locally:

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-IISForge.ps1
```

The GitHub Actions workflow also validates PowerShell syntax on Windows.

## Project Status

IIS Forge is early but usable. The core deployment model is intentionally conservative: release folders, explicit profiles, no hidden app-specific health behavior, and simple rollback.

See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

MIT. See [LICENSE](LICENSE).
