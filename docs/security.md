# Security

## Secrets

Do not commit production secrets into Git.

Use one of these patterns:

- `PreserveFiles` to carry a production file from the active IIS folder into each new release.
- `ConfigOverlayPath` to copy server-only files into the staged release after publish.

Example preserved file:

```json
"PreserveFiles": ["appsettings.Production.json"]
```

Example overlay folder:

```text
<IISForgeRoot>\secure-overlays\example.com
```

## Least Privilege

The deployment command must run elevated because IIS physical path changes require administrator permissions.

The IIS app pool identity only needs read access to release folders and any runtime write folders your app requires.

## Deployment Checkout

Server deployment clones should be treated as disposable. Keep `DiscardLocalChanges` enabled unless you intentionally deploy local server edits.

## Git Credentials

IIS Forge does not store GitHub passwords or tokens. Git authentication is handled by Git Credential Manager, SSH, or the configured Git environment.

## Profiles

Profiles may contain internal paths and repository URLs. Do not put secrets in profiles. If you need secret values, use `ConfigOverlayPath` or environment variables configured outside the repository.
