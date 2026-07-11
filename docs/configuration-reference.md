# Configuration Reference

Profiles are stored as JSON under `profiles\`.

## Required Fields

### `ProfileName`

Human-readable profile identifier. Usually the IIS site name.

### `GitRepositoryUrl`

Git URL used when cloning the repository.

Examples:

```text
https://github.com/owner/repo.git
git@github.com:owner/repo.git
```

### `Branch`

Branch to deploy by default.

### `SiteName`

IIS site name. Used when `IisPath` is blank.

### `RepoPath`

Local Git checkout path. Relative values are resolved under `<IISForgeRoot>`.

### `ReleasesRoot`

Root folder containing timestamped releases for this profile. Relative values are resolved under `<IISForgeRoot>`.

## IIS Fields

### `IisPath`

Optional IIS object path.

For a site:

```text
IIS:\Sites\example.com
```

For an application under a site:

```text
IIS:\Sites\example.com\admin
```

Leave blank to use `IIS:\Sites\<SiteName>`.

### `AppPoolName`

Application pool to recycle after switching the physical path. Leave blank to read it from IIS.

## Build Fields

### `ProjectPath`

Path to a `.csproj`. Leave blank for auto-detect.

If no `.csproj` is found, IIS Forge treats the repository as a static site.

### `SolutionPath`

Path to a `.sln`. Leave blank for auto-detect. Used for restore and test operations when available.

### `StaticPublishPath`

Folder copied to the release when there is no `.csproj`.

If blank, IIS Forge tries:

- `dist`
- `build`
- `public`
- `wwwroot`
- `out`

### `Configuration`

Build configuration for `dotnet publish`. Default:

```text
Release
```

### `RuntimeIdentifier`

Runtime identifier for .NET publish. Common value:

```text
win-x64
```

Set blank for portable framework-dependent publish.

### `SelfContained`

Whether to publish a self-contained .NET app.

## Release Fields

### `KeepReleases`

Number of latest release folders to keep.

### `PreserveFiles`

Files copied from the current IIS physical path into the new release.

Example:

```json
[
  "appsettings.Production.json",
  "web.config"
]
```

### `ConfigOverlayPath`

Folder copied into the new release after build/publish. Use this for server-only config.

### `BackupPreviousPhysicalPathOnlyWhen`

Guard path for backing up a legacy physical folder during first migration.

### `BackupPreviousPhysicalPathTo`

Destination folder for the guarded backup.

## Safety Fields

### `InstallMissingDependencies`

Allows IIS Forge to install missing tools.

### `DiscardLocalChanges`

Treats the deployment checkout as managed and disposable. Tracked local changes are reset before pull.

### `SkipBrowserslistUpdate`

Suppresses Browserslist/caniuse-lite update behavior to avoid mutating lockfiles on the server.

### `DisableConsoleQuickEdit`

Disables Windows console QuickEdit mode so accidental text selection does not pause deployment.
