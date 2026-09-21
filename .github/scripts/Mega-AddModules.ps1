<#
.SYNOPSIS
    Adds immutable external module release artifacts to Mega Release staging.

.DESCRIPTION
    For each module from release.config.json:
      1. gets the latest published GitHub Release;
      2. freezes its tag and concrete release asset;
      3. downloads the selected ZIP;
      4. verifies SHA-256 using the published Release asset digest;
      5. extracts only the directory named module.name;
      6. copies the module Release root-level MD next to the Mega MD.

    External module sources are never checked out or built.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$configPath = Join-Path $env:GITHUB_WORKSPACE $env:RELEASE_CONFIG_FILE
$stagingDirectory = $env:STAGING_DIRECTORY

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Release configuration was not found: $configPath"
}
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Mega staging directory was not found: $stagingDirectory"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
if ($null -eq $config.modules) {
    throw "Release configuration property 'modules' is required for Mega Release."
}

$modules = @($config.modules)
if ($modules.Count -eq 0) {
    Write-Host 'No Mega Release modules are configured.'
    exit 0
}

$megaModuleNames = @{}
foreach ($module in $modules) {
    $name = [string]$module.name
    $repository = [string]$module.repository

    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'Every Mega Release module must define a non-empty name.'
    }
    if ($repository -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "Invalid module repository '$repository'. Expected owner/repository."
    }
    if ($name -match '[\\/:*?"<>|]') {
        throw "Invalid module name '$name'. Module name cannot contain path separator or Windows filename characters."
    }
    if ($megaModuleNames.ContainsKey($name)) {
        throw "Duplicate Mega Release module name: '$name'."
    }

    $megaModuleNames[$name] = $true
}

$downloadRoot = Join-Path $env:RUNNER_TEMP ("MegaModules_" + $env:GITHUB_RUN_ID)
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

$lock = @()

function Get-LatestRelease {
    param([Parameter(Mandatory)][string]$Repository)

    $json = gh api "repos/$Repository/releases/latest" --header "Accept: application/vnd.github+json"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not get latest published release for '$Repository'."
    }

    return ($json | ConvertFrom-Json)
}

function Download-Asset {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)][string]$Directory
    )

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null

    gh release download $Tag `
        --repo $Repository `
        --pattern $AssetName `
        --dir $Directory `
        --clobber

    if ($LASTEXITCODE -ne 0) {
        throw "Could not download asset '$AssetName' from '$Repository' release '$Tag'."
    }

    $path = Join-Path $Directory $AssetName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Downloaded asset was not found: $path"
    }

    return $path
}

function Copy-ZipEntry {
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)][string] $DestinationRoot
    )

    $entryName = $Entry.FullName.Replace('\','/')
    $segments = @($entryName -split '/')
    if ($segments | Where-Object { $_ -eq '..' }) {
        throw "Unsafe ZIP entry path: '$entryName'."
    }
    if ([System.IO.Path]::IsPathRooted($entryName)) {
        throw "Unsafe rooted ZIP entry path: '$entryName'."
    }

    $relativeName = $entryName.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $destination = Join-Path $DestinationRoot $relativeName

    if ($Entry.FullName.EndsWith('/')) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        return
    }

    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null

    $input = $Entry.Open()
    try {
        $output = [System.IO.File]::Create($destination)
        try {
            $input.CopyTo($output)
        }
        finally {
            $output.Dispose()
        }
    }
    finally {
        $input.Dispose()
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

foreach ($module in $modules) {
    $name = [string]$module.name
    $repository = [string]$module.repository

    Write-Host ("=== Mega module: " + $name + " ===")
    Write-Host ("Repository: " + $repository)

    # latest is called once. The selected tag and asset are then fixed for
    # this run even if another Module Release appears later.
    $release = Get-LatestRelease -Repository $repository
    $tag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($tag)) {
        throw "Latest release of '$repository' does not contain tag_name."
    }

    $zipAssets = @($release.assets | Where-Object {
        $_.state -eq 'uploaded' -and
        $_.name -match '\.zip$'
    })

    if ($zipAssets.Count -ne 1) {
        throw "Expected exactly one ZIP release asset in '$repository' release '$tag'; found $($zipAssets.Count)."
    }

    $asset = $zipAssets[0]
    $assetName = [string]$asset.name
    $digest = [string]$asset.digest

    if ($digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw "Release asset '$assetName' in '$repository' has no valid SHA-256 digest."
    }

    $expectedHash = $digest.Substring(7).ToLowerInvariant()
    $moduleRoot = Join-Path $stagingDirectory $name
    if (Test-Path -LiteralPath $moduleRoot) {
        throw "Mega staging already contains module directory '$name'."
    }

    $moduleDownloadDirectory = Join-Path $downloadRoot $name
    $archivePath = Download-Asset -Repository $repository -Tag $tag -AssetName $assetName -Directory $moduleDownloadDirectory

    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch for '$repository' release '$tag' asset '$assetName'. Expected '$expectedHash', actual '$actualHash'."
    }

    Write-Host ("Release fixed: " + $tag)
    Write-Host ("Artifact fixed: " + $assetName)
    Write-Host ("SHA-256 verified: " + $actualHash)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $prefix = $name + "/"
        $moduleEntries = @($archive.Entries | Where-Object {
            $_.FullName.Replace('\','/').StartsWith($prefix, [System.StringComparison]::Ordinal)
        })

        if ($moduleEntries.Count -eq 0) {
            throw "Module directory '$name' was not found in artifact '$assetName'."
        }

        foreach ($entry in $moduleEntries) {
            Copy-ZipEntry -Entry $entry -DestinationRoot $stagingDirectory
        }

        # Existing module releases put their product/version Markdown file
        # at archive root. It is published beside the Mega Markdown file.
        $rootMarkdown = @($archive.Entries | Where-Object {
            -not $_.FullName.Replace('\','/').Contains('/') -and
            $_.FullName -match '\.md$'
        })

        if ($rootMarkdown.Count -ne 1) {
            throw "Expected exactly one root-level MD file in '$repository' release '$tag'; found $($rootMarkdown.Count)."
        }

        $moduleMarkdownName = [System.IO.Path]::GetFileName($rootMarkdown[0].FullName)
        $megaMarkdownPath = Join-Path $stagingDirectory $moduleMarkdownName
        if (Test-Path -LiteralPath $megaMarkdownPath) {
            throw "Module Markdown '$moduleMarkdownName' would overwrite an existing Mega release file."
        }

        Copy-ZipEntry -Entry $rootMarkdown[0] -DestinationRoot $stagingDirectory
    }
    finally {
        $archive.Dispose()
    }

    $lock += [pscustomobject]@{
        name = $name
        repository = $repository
        release = $tag
        artifact = $assetName
        sha256 = $actualHash
    }
}

$lockPath = Join-Path $env:RUNNER_TEMP ("mega-modules-" + $env:GITHUB_RUN_ID + ".lock.json")
$lock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $lockPath -Encoding utf8NoBOM

Write-Host '=== Mega module selection ==='
$lock | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("Module lock: " + $lockPath)
