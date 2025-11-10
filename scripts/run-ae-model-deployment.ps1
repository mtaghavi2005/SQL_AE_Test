#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory=$true)] [string] $ConnectionString,
    [Parameter(Mandatory=$true)] [string] $AkvKeyId,
    [Parameter(Mandatory=$true)] [string] $CmkName,
    [Parameter(Mandatory=$true)] [string] $ProjectPath,
    [Parameter(Mandatory=$true)] [string] $DbSchema,
    [string] $LogFileDirectory = "./logs",
    [switch] $UseOnlineApproach,
    [int] $MaxDowntimeInSeconds = 180,
    [switch] $Cleanup
)

$ErrorActionPreference = 'Stop'

Write-Host "🚀 Always Encrypted Model Deployment" -ForegroundColor Cyan
Write-Host "====================================" -ForegroundColor Cyan

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

# If relative path, resolve it relative to repo root
if (-not [System.IO.Path]::IsPathRooted($ProjectPath)) {
    $projectPath = Join-Path $repoRoot $ProjectPath
} else {
    $projectPath = $ProjectPath
}

if (-not (Test-Path $projectPath)) {
    throw "Unable to locate project file at $projectPath"
}

Write-Host "📦 Project: $projectPath" -ForegroundColor Gray
Write-Host ""

$dotnetArgs = @('run', '--project', $projectPath, '--', 'ae-dump-targets')
Write-Host "📤 Discovering Always Encrypted targets from EF Core model..." -ForegroundColor Green
$targetsJson = & dotnet @dotnetArgs
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    throw "dotnet run failed while gathering AE targets (exit code $exitCode). Output: $targetsJson"
}

if ([string]::IsNullOrWhiteSpace($targetsJson)) {
    throw "The EF model did not produce any Always Encrypted target information."
}

try {
    $aeTargets = $targetsJson | ConvertFrom-Json
    if ($aeTargets -isnot [System.Array]) {
        $aeTargets = @($aeTargets)
    }
} catch {
    throw "Failed to parse Always Encrypted targets JSON. Details: $($_.Exception.Message). Raw output: $targetsJson"
}

Write-Host "  Found $($aeTargets.Count) column targets in model" -ForegroundColor Gray
Write-Host ""

$modulePath = Join-Path $repoRoot "scripts/AE-Helper.psm1"
if (-not (Test-Path $modulePath)) {
    throw "Unable to locate AE helper module at $modulePath"
}

Import-Module $modulePath -Force

$invokeArgs = @{
    ConnectionString = $ConnectionString
    AkvKeyId = $AkvKeyId
    MigrationId = 'CurrentModelDeployment'
    AeTargets = $aeTargets
    CmkName = $CmkName
}

if ($UseOnlineApproach) {
    $invokeArgs.UseOnlineApproach = $true
    $invokeArgs.MaxDowntimeInSeconds = $MaxDowntimeInSeconds
}

if ($LogFileDirectory) {
    $invokeArgs.LogFileDirectory = $LogFileDirectory
}

Write-Host "🛠️  Applying model-based Always Encrypted configuration..." -ForegroundColor Green
Invoke-AlwaysEncryptedMigration @invokeArgs

if ($Cleanup) {
    Write-Host ""
    Write-Host "🧹 Running cleanup for orphaned Always Encrypted objects..." -ForegroundColor Cyan
    $cleanupResult = Remove-OrphanedAlwaysEncryptedObjects -ConnectionString $ConnectionString -CurrentAeTargets $aeTargets -SchemaName $DbSchema
    if ($cleanupResult) {
        Write-Host "Cleanup summary:" -ForegroundColor Gray
        Write-Host "  Decrypted columns: $($cleanupResult.DecryptedColumns -join ', ')" -ForegroundColor Gray
        Write-Host "  Removed CEKs: $($cleanupResult.RemovedCEKs -join ', ')" -ForegroundColor Gray
        Write-Host "  Removed CMKs: $($cleanupResult.RemovedCMKs -join ', ')" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "🎉 Model-based Always Encrypted deployment finished" -ForegroundColor Magenta
