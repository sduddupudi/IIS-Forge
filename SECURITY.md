# Security Policy

## Reporting Security Issues

Do not open a public issue for sensitive security problems.

Email the maintainer or use GitHub private vulnerability reporting if enabled for the repository.

## Secrets

IIS Forge should not store credentials in profiles, examples, or generated launchers.

Recommended secret patterns:

- environment variables configured outside the repository
- IIS configuration managed outside the repository
- `ConfigOverlayPath` folders secured on the server
- `PreserveFiles` for existing production-only files

## Supported Versions

The project is pre-1.0. Security fixes are expected to land on `main` until formal releases are introduced.
