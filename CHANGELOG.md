# Changelog

## 0.1.1

- Added flat root scripts (`iis-forge.ps1`, `new-iis-forge-profile.ps1`, `Test-IISForge.ps1`) so server installs can keep everything directly under one folder without a required `scripts\` subfolder.
- Profile wizard now restores missing `iis-forge.ps1` from a local copy or GitHub before creating launchers, preventing profiles that cannot deploy.
- Profile wizard now refuses accidental drive-root install roots and asks for a real install folder, preventing launchers from being created at the drive root.
- Generated launchers now resolve the engine/profile from their own folder without embedding a machine-specific install path.
- Clarified install-root behavior: generated profiles, launchers, repos, releases, and backups stay under the IIS Forge install folder by default.
- Improved direct engine UX: running `iis-forge.ps1` without a site/profile now prints first-run wizard guidance instead of showing PowerShell's raw `SiteName` prompt.
- Expanded README with badges, feature matrix, supported targets, and validation notes.
- Added architecture, configuration reference, operations runbook, and versioning documentation.
- Added support and security policy documents.
- Added GitHub Actions parser validation workflow.
- Added issue templates and pull request template.
- Added local validation script: `Test-IISForge.ps1`.
- Added `.editorconfig` and `.gitattributes` for consistent formatting.
- Added generated launcher example.

## 0.1.0

- Initial IIS Forge release.
- Shared IIS deployment engine.
- First-run profile wizard.
- Per-site generated deploy launchers.
- Git clone/pull support.
- Dependency bootstrapping for Git, Node.js, .NET SDK, ASP.NET Core Hosting Bundle, and IIS management tooling.
- Dynamic .NET major version detection from `.csproj` and `global.json`.
- ASP.NET Core publish support.
- Static site publish support.
- Release-folder switching for IIS.
- App pool recycle.
- Preserved production files and config overlays.
- Old release cleanup.
- Optional first-migration backup of previous IIS physical path.
- No built-in HTTP health checks.
