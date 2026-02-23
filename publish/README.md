# Publish Scripts

## `publish-release.ps1`

Builds, tests, packs, optionally pushes NuGet packages, and can reinstall global tools for both `RoslynMcp.Server` (`roslyn-mcp`) and `RoslynMcp.Cli` (`roslyn-cli`).

### Typical release publish

```powershell
.\publish\publish-release.ps1 -PushToNuGet
```

The script reads `NUGET_API_KEY` from the environment (or pass `-NuGetApiKey`).

### Build and pack only (no publish)

```powershell
.\publish\publish-release.ps1
```

### Reinstall `roslyn-mcp` with same version from local artifacts

```powershell
.\publish\publish-release.ps1 -SkipTests -ReinstallGlobalTool
```

This flow:

1. Packs `RoslynMcp.Server` (and related packages) to `publish/artifacts`.
2. Uninstalls global tool `RoslynMcp.Server` if installed.
3. Reinstalls the same version from local packages.
4. Uses an isolated cache folder (`publish/.tool-install-cache`) so it does not clear your global NuGet cache.

### Reinstall `roslyn-cli` with same version from local artifacts

```powershell
.\publish\publish-release.ps1 -SkipTests -ReinstallCliTool
```

### Reinstall both global tools with same versions from local artifacts

```powershell
.\publish\publish-release.ps1 -SkipTests -ReinstallGlobalTool -ReinstallCliTool
```

### Shortcut: reinstall both tools (same as the command above)

```powershell
.\publish\publish-release.ps1 --reinstall
```

### Reinstall global tools from NuGet instead of local artifacts

```powershell
.\publish\publish-release.ps1 -SkipTests -ReinstallGlobalTool -ReinstallCliTool -InstallFromNuGet
```

### Explicitly clear all global NuGet packages cache (optional)

```powershell
.\publish\publish-release.ps1 -ClearNuGetCache
```

## Notes

- NuGet.org does not allow replacing an already published package version.
- `-PushToNuGet` uses `--skip-duplicate`, so if that version already exists it will be skipped, not overwritten.
