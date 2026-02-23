[CmdletBinding()]
param(
    [ValidateSet("Release", "Debug")]
    [string]$Configuration = "Release",

    [switch]$SkipRestore,
    [switch]$SkipBuild,
    [switch]$SkipTests,

    [switch]$PushToNuGet,
    [string]$NuGetApiKey = $env:NUGET_API_KEY,
    [string]$NuGetSource = "https://api.nuget.org/v3/index.json",

    [switch]$Reinstall,
    [switch]$ReinstallGlobalTool,
    [switch]$ReinstallCliTool,
    [switch]$InstallFromNuGet,
    [switch]$ClearNuGetCache,
    [string]$ToolInstallCacheDir,

    [string]$PackageOutputDir,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-DotNet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ("dotnet " + ($Arguments -join " "))
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet command failed with exit code $LASTEXITCODE"
    }
}

function Get-CsprojProperty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsprojPath,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    [xml]$projectXml = Get-Content -Path $CsprojPath -Raw
    foreach ($group in $projectXml.Project.PropertyGroup) {
        $node = $group.$PropertyName
        if ($null -ne $node -and -not [string]::IsNullOrWhiteSpace([string]$node)) {
            return [string]$node
        }
    }

    throw "Could not find property '$PropertyName' in '$CsprojPath'."
}

function Test-GlobalToolInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $toolListOutput = & dotnet tool list -g
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list global tools."
    }

    $pattern = "^\s*" + [Regex]::Escape($PackageId) + "\s+"
    return [bool]($toolListOutput | Select-String -Pattern $pattern)
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot "..")
$solutionPath = Join-Path $repoRoot "RoslynMcp.sln"

if (-not $PackageOutputDir) {
    $PackageOutputDir = Join-Path $scriptRoot "artifacts"
}

if (-not $ToolInstallCacheDir) {
    $ToolInstallCacheDir = Join-Path $scriptRoot ".tool-install-cache"
}

if ($RemainingArgs) {
    foreach ($arg in $RemainingArgs) {
        switch -Regex ($arg.ToLowerInvariant()) {
            "^--reinstall$" {
                $Reinstall = $true
                continue
            }
            default {
                throw "Unknown argument '$arg'. Supported extra argument: --reinstall"
            }
        }
    }
}

if ($Reinstall) {
    Write-Host "Shortcut '-Reinstall' enabled: applying -SkipTests -ReinstallGlobalTool -ReinstallCliTool"
    $SkipTests = $true
    $ReinstallGlobalTool = $true
    $ReinstallCliTool = $true
}

$projectsToPack = @(
    "src/RoslynMcp.Contracts/RoslynMcp.Contracts.csproj",
    "src/RoslynMcp.Core/RoslynMcp.Core.csproj",
    "src/RoslynMcp.Server/RoslynMcp.Server.csproj",
    "src/RoslynMcp.Cli/RoslynMcp.Cli.csproj"
)

Write-Host "Repository root: $repoRoot"
Write-Host "Package output: $PackageOutputDir"
Write-Host ""

if (-not $SkipRestore) {
    Write-Host "Restoring solution..."
    Invoke-DotNet -Arguments @("restore", $solutionPath)
    Write-Host ""
}

if (-not $SkipBuild) {
    Write-Host "Building solution..."
    $buildArgs = @("build", $solutionPath, "-c", $Configuration)
    if (-not $SkipRestore) {
        $buildArgs += "--no-restore"
    }

    Invoke-DotNet -Arguments $buildArgs
    Write-Host ""
}

if (-not $SkipTests) {
    Write-Host "Running tests..."
    $testArgs = @("test", $solutionPath, "-c", $Configuration)
    if (-not $SkipBuild) {
        $testArgs += "--no-build"
    }
    elseif (-not $SkipRestore) {
        $testArgs += "--no-restore"
    }

    Invoke-DotNet -Arguments $testArgs
    Write-Host ""
}

if (Test-Path $PackageOutputDir) {
    Remove-Item -Path $PackageOutputDir -Recurse -Force
}
New-Item -ItemType Directory -Path $PackageOutputDir -Force | Out-Null

Write-Host "Packing projects..."
foreach ($relativeProjectPath in $projectsToPack) {
    $projectPath = Join-Path $repoRoot $relativeProjectPath
    $packArgs = @("pack", $projectPath, "-c", $Configuration, "-o", $PackageOutputDir)
    if (-not $SkipBuild) {
        $packArgs += "--no-build"
    }
    elseif (-not $SkipRestore) {
        $packArgs += "--no-restore"
    }

    Invoke-DotNet -Arguments $packArgs
}
Write-Host ""

$packagesToPush = Get-ChildItem -Path $PackageOutputDir -File |
    Where-Object { $_.Extension -eq ".nupkg" -or $_.Extension -eq ".snupkg" } |
    Sort-Object Name

if ($PushToNuGet) {
    if ([string]::IsNullOrWhiteSpace($NuGetApiKey)) {
        throw "NuGet API key not set. Pass -NuGetApiKey or set NUGET_API_KEY environment variable."
    }

    Write-Host "Pushing packages to NuGet..."
    foreach ($pkg in $packagesToPush) {
        Invoke-DotNet -Arguments @(
            "nuget", "push", $pkg.FullName,
            "--api-key", $NuGetApiKey,
            "--source", $NuGetSource,
            "--skip-duplicate"
        )
    }
    Write-Host ""
}

if ($ReinstallGlobalTool -or $ReinstallCliTool) {
    $toolProjectPaths = @()
    if ($ReinstallGlobalTool) {
        $toolProjectPaths += "src/RoslynMcp.Server/RoslynMcp.Server.csproj"
    }
    if ($ReinstallCliTool) {
        $toolProjectPaths += "src/RoslynMcp.Cli/RoslynMcp.Cli.csproj"
    }

    $useLocalSource = -not $InstallFromNuGet
    if ($ClearNuGetCache) {
        Write-Host "Clearing global NuGet cache as requested..."
        Invoke-DotNet -Arguments @("nuget", "locals", "global-packages", "--clear")
    }

    $previousNuGetPackages = $env:NUGET_PACKAGES
    if ($useLocalSource) {
        # Install from local artifacts only, and use an isolated package cache so same-version installs
        # do not reuse previously cached global packages.
        New-Item -ItemType Directory -Path $ToolInstallCacheDir -Force | Out-Null
        $env:NUGET_PACKAGES = $ToolInstallCacheDir
    }

    try {
        foreach ($toolProjectPath in $toolProjectPaths) {
            $resolvedToolProjectPath = Join-Path $repoRoot $toolProjectPath
            $toolPackageId = Get-CsprojProperty -CsprojPath $resolvedToolProjectPath -PropertyName "PackageId"
            $toolVersion = Get-CsprojProperty -CsprojPath $resolvedToolProjectPath -PropertyName "Version"

            Write-Host "Reinstalling global tool '$toolPackageId' version '$toolVersion'..."

            if (Test-GlobalToolInstalled -PackageId $toolPackageId) {
                Invoke-DotNet -Arguments @("tool", "uninstall", "-g", $toolPackageId)
            }
            else {
                Write-Host "Global tool '$toolPackageId' is not installed. Skipping uninstall."
            }

            $installArgs = @("tool", "install", "-g", $toolPackageId, "--version", $toolVersion)
            if ($useLocalSource) {
                $installArgs += @("--source", $PackageOutputDir, "--no-http-cache")
            }

            Invoke-DotNet -Arguments $installArgs
            Write-Host ""
        }
    }
    finally {
        if ($useLocalSource) {
            if ([string]::IsNullOrEmpty($previousNuGetPackages)) {
                Remove-Item Env:NUGET_PACKAGES -ErrorAction SilentlyContinue
            }
            else {
                $env:NUGET_PACKAGES = $previousNuGetPackages
            }
        }
    }
}

Write-Host "Done."
Write-Host "Created packages:"
Get-ChildItem -Path $PackageOutputDir -File |
    Where-Object { $_.Extension -eq ".nupkg" -or $_.Extension -eq ".snupkg" } |
    Sort-Object Name |
    ForEach-Object { Write-Host (" - " + $_.Name) }

if (-not $PushToNuGet) {
    Write-Host ""
    Write-Host "Packages were not pushed. Use -PushToNuGet to publish."
}
