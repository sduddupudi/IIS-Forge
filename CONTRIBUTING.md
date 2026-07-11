# Contributing

Thanks for improving IIS Forge.

## Local Validation

Before opening a change, run PowerShell parser validation:

```powershell
$files = @(
  ".\iis-forge.ps1",
  ".\new-iis-forge-profile.ps1",
  ".\Test-IISForge.ps1"
)

foreach ($file in $files) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    $errors | Format-List *
    throw "Parser errors in $file"
  }
}
```

## Design Rules

- Keep the engine app-agnostic.
- Do not add app-specific health checks.
- Prefer release-folder deployment over in-place file replacement.
- Keep profiles as data and generated launchers as thin wrappers.
- Avoid storing secrets in profiles or examples.
- Use official installers/package IDs for dependencies.

## Pull Request Notes

Describe:

- what changed
- why it matters
- how it was validated
- any server compatibility concerns
