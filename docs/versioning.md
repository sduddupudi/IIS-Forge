# Versioning

IIS Forge uses semantic versioning after `1.0.0`.

## Current Status

`0.x` releases may adjust profile shape, script parameters, or defaults as the project matures.

## Compatibility Goals

IIS Forge tries to preserve:

- profile JSON compatibility
- generated launcher compatibility
- release folder layout
- documented command-line switches

## Future .NET Versions

IIS Forge is designed to handle future .NET majors without code changes when Microsoft preserves the package and download naming patterns:

```text
Microsoft.DotNet.SDK.<major>
Microsoft.DotNet.HostingBundle.<major>
dotnet-install.ps1 -Channel <major>.0
https://aka.ms/dotnet/<major>.0/dotnet-hosting-win.exe
```

If Microsoft changes those patterns, IIS Forge may need an engine update.

## Changelog

Every user-facing release should update `CHANGELOG.md`.
