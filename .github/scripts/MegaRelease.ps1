<#
.SYNOPSIS
    Mega Release entry point for staging the primary release and immutable modules.

.DESCRIPTION
    Keeps the Mega Release orchestration entry point in one script while reusing
    the existing release staging contract.

    The script deliberately does not build or checkout external module sources.
    Mega-StageReleaseFiles.ps1 performs the existing primary staging and then
    adds immutable module Release artifacts configured in release.config.json.

    Environment:
      RELEASE_CONFIG_FILE - repository-relative release configuration path.
      GITHUB_OUTPUT       - GitHub Actions output file.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = $env:GITHUB_WORKSPACE
if ([string]::IsNullOrWhiteSpace($workspace)) {
    throw 'GITHUB_WORKSPACE is required.'
}

$releaseConfigFile = $env:RELEASE_CONFIG_FILE
if ([string]::IsNullOrWhiteSpace($releaseConfigFile)) {
    $releaseConfigFile = '.github/release-settings/release.config.json'
}

$configPath = Join-Path $workspace $releaseConfigFile
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Release configuration was not found: $configPath"
}

$stageScript = Join-Path $workspace '.github/scripts/Mega-StageReleaseFiles.ps1'
if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
    throw "Mega staging script was not found: $stageScript"
}

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT is required.'
}

Write-Host '=== Mega Release staging ==='
Write-Host "Configuration: $configPath"
Write-Host "Staging entry point: $stageScript"

& $stageScript
if ($LASTEXITCODE -ne 0) {
    throw "Mega-StageReleaseFiles.ps1 failed with exit code $LASTEXITCODE."
}

$outputLines = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
$stagingLine = $outputLines |
    Where-Object { $_ -like 'staging_directory=*' } |
    Select-Object -Last 1

if ($null -eq $stagingLine) {
    throw 'Mega staging did not produce staging_directory output.'
}

$stagingDirectory = $stagingLine.Substring('staging_directory='.Length)
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Mega staging directory was not found: $stagingDirectory"
}

Write-Host "Mega staging directory: $stagingDirectory"
