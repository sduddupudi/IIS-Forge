# Installation

## Requirements

- Windows Server or Windows with IIS
- Elevated Windows PowerShell
- Network access to the Git repository
- Permission to modify the IIS site/application physical path

IIS Forge can install missing tools when profile setting `InstallMissingDependencies` is `true`.

## Install From Git

Choose any install folder. IIS Forge keeps generated profiles, launchers, cloned repos, release folders, and backups inside that folder by default.

```powershell
git clone https://github.com/sduddupudi/IIS-Forge.git <IISForgeRoot>
cd <IISForgeRoot>
```

If Git is not installed yet, download the repository as a ZIP, extract it to your chosen install folder, and run the profile wizard from there. The deploy engine can install Git during deployment.

## Create First Profile

```powershell
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1
```

Start with the profile wizard, not `iis-forge.ps1`. The `iis-forge.ps1` file is the shared engine used by generated launchers and advanced direct calls.

The wizard creates:

- `profiles\<profile>.json`
- `<profile>.deploy.ps1`
- default folders under `repos\`, `releases\`, and `backups\`

## Where Files Are Created

Everything is relative to the folder where IIS Forge is installed unless you override a path in the wizard with an absolute path.

If IIS Forge is installed at:

```text
<IISForgeRoot>
```

then the wizard defaults to:

```text
<IISForgeRoot>\profiles\<profile>.json
<IISForgeRoot>\<profile>.deploy.ps1
<IISForgeRoot>\repos\<profile>
<IISForgeRoot>\releases\<profile>
<IISForgeRoot>\backups\<profile>
```

If tomorrow you install it at another folder, the generated defaults move with that folder.

## Deploy

```powershell
powershell -ExecutionPolicy Bypass -File .\<profile>.deploy.ps1
```

## Upgrade IIS Forge

Because launchers call the shared engine, upgrading is simple:

```powershell
cd <IISForgeRoot>
git pull
```

Existing profiles and generated launchers stay in place.

## Multi-Site Setup

Run the wizard once per site:

```powershell
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName example.com
powershell -ExecutionPolicy Bypass -File .\new-iis-forge-profile.ps1 -ProfileName api.example.com
```

Each site gets its own profile and launcher, while all sites share `iis-forge.ps1`.
