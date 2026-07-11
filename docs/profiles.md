# Profiles

Profiles are JSON files under `profiles\`. Each profile describes one IIS site or application.

## Folder Names in Plain English

`Current IIS website folder`

The folder IIS serves before IIS Forge deploys. Existing IIS sites often use a folder like `<SiteContentRoot>\<site>`. IIS Forge reads this from IIS automatically and can back it up on the first deploy.

`RepoPath`

Where IIS Forge clones source code.

`StaticPublishPath`

A folder inside the repo that already contains finished static files. Leave it blank for ASP.NET Core apps with a `.csproj`.

`ReleasesRoot`

Where IIS Forge creates deploy output. After deploy, IIS points to the newest timestamped folder under this root.

## Important Fields

`GitRepositoryUrl`

The repository to clone when `RepoPath` does not exist. HTTPS, SSH, and Git Credential Manager flows are supported by Git itself.

`Branch`

The branch to deploy. Generated launchers allow temporary override with `-Branch`.

`SiteName`

IIS site name. If `IisPath` is blank, IIS Forge uses `IIS:\Sites\<SiteName>` semantics internally through the IIS management API.

`IisPath`

Optional IIS object path. Use this for applications under a site, for example:

```text
IIS:\Sites\example.com\admin
```

This is not a disk path.

`RepoPath`

Local checkout path. Relative values are resolved under `<IISForgeRoot>`, so the wizard default is `repos\<profile>`.

`ProjectPath`

Path to `.csproj`. Leave blank when there is only one deployable project. If no project exists, IIS Forge treats the repo as a static site.

`StaticPublishPath`

Folder copied to the release when there is no `.csproj`. Leave blank to auto-detect:

- `dist`
- `build`
- `public`
- `wwwroot`
- `out`

`ReleasesRoot`

Folder where timestamped releases are stored. Relative values are resolved under `<IISForgeRoot>`, so the wizard default is `releases\<profile>`.

`ConfigOverlayPath`

Optional secure folder copied over the staged release after publish. Use this for server-only production config that should not be committed to Git.
Relative values are resolved under `<IISForgeRoot>`.

`PreserveFiles`

Files copied from the currently active IIS physical path into the new release. Common value:

```json
["appsettings.Production.json"]
```

`BackupPreviousPhysicalPathOnlyWhen`

Optional guard path for the first migration from a manually managed folder. IIS Forge moves or copies the old folder only when the previous IIS physical path matches this value.

`InstallMissingDependencies`

When true, IIS Forge tries to install missing dependencies.

`DiscardLocalChanges`

When true, the deployment checkout is treated as disposable and tracked local changes are reset before pull. This is recommended for server-side deployment clones.

## Reconfigure

```powershell
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName example.com -Configure
```
