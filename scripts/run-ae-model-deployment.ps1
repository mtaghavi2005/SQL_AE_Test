#!/usr/bin/env pwsh
param(
    [Parameter(Mandatory=$true)] [string] $ConnectionString,
    [Parameter(Mandatory=$true)] [string] $KeyVaultName,
    [Parameter(Mandatory=$true)] [string] $CmkName,
    [Parameter(Mandatory=$true)] [string] $AeTargetsJsonFile,
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
if (-not [System.IO.Path]::IsPathRooted($AeTargetsJsonFile)) {
    $targetsJsonPath = Join-Path $repoRoot $AeTargetsJsonFile
} else {
    $targetsJsonPath = $AeTargetsJsonFile
}

if (-not (Test-Path $targetsJsonPath)) {
    throw "Unable to locate targets JSON file at $targetsJsonPath"
}

Write-Host "📦 Targets JSON: $targetsJsonPath" -ForegroundColor Gray
Write-Host ""

Write-Host "📤 Loading Always Encrypted targets from JSON file..." -ForegroundColor Green
$targetsJson = Get-Content -Path $targetsJsonPath -Raw

if ([string]::IsNullOrWhiteSpace($targetsJson)) {
    throw "The targets JSON file is empty."
}

try {
    $aeTargets = $targetsJson | ConvertFrom-Json
    if ($aeTargets -isnot [System.Array]) {
        $aeTargets = @($aeTargets)
    }
} catch {
    throw "Failed to parse Always Encrypted targets JSON. Details: $($_.Exception.Message)"
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
    KeyVaultName = $KeyVaultName
    AeTargets = $aeTargets
    DbSchema = $DbSchema    
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
    $cleanupResult = Remove-OrphanedAlwaysEncryptedObjects -ConnectionString $ConnectionString -CurrentAeTargets $aeTargets  -SchemaName $DbSchema
}

Write-Host ""
Write-Host "🎉 Model-based Always Encrypted deployment finished" -ForegroundColor Magenta
