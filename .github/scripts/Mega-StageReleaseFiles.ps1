<#
.SYNOPSIS
    Stages the existing primary Release output for Mega Release.

.DESCRIPTION
    This is a thin Mega-specific wrapper around the existing staging contract.
    It first runs the existing Stage-ReleaseFiles.ps1 and then adds immutable
    external module artifacts. The existing primary-module packaging logic is
    therefore reused without modification.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stageScript = Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Stage-ReleaseFiles.ps1'
if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
    throw "Existing release staging script was not found: $stageScript"
}

& $stageScript
if ($LASTEXITCODE -ne 0) {
    throw "Stage-ReleaseFiles.ps1 failed with exit code $LASTEXITCODE."
}

$existingOutput = Get-Content -LiteralPath $env:GITHUB_OUTPUT -Tail 1 -ErrorAction SilentlyContinue
$stagingDirectory = $null

# Stage-ReleaseFiles.ps1 writes staging_directory to GITHUB_OUTPUT. Read it
# back from the file so its existing script remains untouched.
$outputLines = @(Get-Content -LiteralPath $env:GITHUB_OUTPUT)
$stagingLine = $outputLines | Where-Object { $_ -like 'staging_directory=*' } | Select-Object -Last 1
if ($null -eq $stagingLine) {
    throw 'Stage-ReleaseFiles.ps1 did not produce staging_directory output.'
}

$stagingDirectory = $stagingLine.Substring('staging_directory='.Length)
if (-not (Test-Path -LiteralPath $stagingDirectory -PathType Container)) {
    throw "Staging directory was not found: $stagingDirectory"
}

$env:STAGING_DIRECTORY = $stagingDirectory
& (Join-Path $env:GITHUB_WORKSPACE '.github/scripts/Mega-AddModules.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "Mega-AddModules.ps1 failed with exit code $LASTEXITCODE."
}

# Expose the same staging directory for the existing archive/manifest scripts.
"staging_directory=$stagingDirectory" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
