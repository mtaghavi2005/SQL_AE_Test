#!/usr/bin/env pwsh
# Always Encrypted Migration Sidecar Runner
# Runs the generated *_AE.ps1 migration files with environment variables

param(
    [string] $ConnectionString = $env:SQL_CONNECTION_STRING,
    [string] $AkvKeyId = $env:AKV_KEY_ID,
    [string] $CmkName = $env:AE_CMK_NAME,
    [string] $MigrationScript = $env:AE_MIGRATION_SCRIPT,
    [bool] $UseOnlineApproach = $true,
    [int] $MaxDowntimeInSeconds = 180,
    [string] $LogFileDirectory = "./logs"
)

Write-Host "🚀 Always Encrypted Migration Runner" -ForegroundColor Cyan
Write-Host "===================================" -ForegroundColor Cyan

# Find the migration script to run
if ([string]::IsNullOrWhiteSpace($MigrationScript)) {
    Write-Host "🔍 Finding latest migration sidecar..." -ForegroundColor Yellow
    $migrationFiles = Get-ChildItem -Path ".." -Filter "*_AE.ps1" -Recurse | Sort-Object Name -Descending
    if ($migrationFiles.Count -eq 0) {
        Write-Host "❌ No migration sidecar files (*_AE.ps1) found!" -ForegroundColor Red
        Write-Host "   Generate migrations first: dotnet ef migrations add MyMigration" -ForegroundColor Gray
        exit 1
    }
    $MigrationScript = $migrationFiles[0].FullName
    Write-Host "  Found: $($migrationFiles[0].Name)" -ForegroundColor Green
} else {
    if (-not (Test-Path $MigrationScript)) {
        Write-Host "❌ Migration script not found: $MigrationScript" -ForegroundColor Red
        exit 1
    }
}

# Validate required parameters
$requiredParams = @{
    'ConnectionString' = $ConnectionString
    'AkvKeyId' = $AkvKeyId
    'CmkName' = $CmkName
    'MigrationScript' = $MigrationScript
}

$missing = @()
foreach ($param in $requiredParams.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($param.Value)) {
        $missing += $param.Key
    }
}

if ($missing.Count -gt 0) {
    Write-Host "❌ Missing required parameters: $($missing -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "Set environment variables or pass parameters:" -ForegroundColor Yellow
    Write-Host "  SQL_CONNECTION_STRING, AKV_KEY_ID, AE_CMK_NAME, AE_MIGRATION_SCRIPT" -ForegroundColor Gray
    exit 1
}

Write-Host "📋 Configuration:" -ForegroundColor Green
Write-Host "  Connection String: $($ConnectionString -replace 'Password=[^;]+', 'Password=***')" -ForegroundColor Gray
Write-Host "  AKV Key ID: $AkvKeyId" -ForegroundColor Gray
Write-Host "  CMK Name: $CmkName" -ForegroundColor Gray
Write-Host "  Migration Script: $MigrationScript" -ForegroundColor Gray
Write-Host ""

# Run the migration sidecar script
Write-Host "🚀 Executing migration sidecar: $MigrationScript" -ForegroundColor Green
Write-Host ""

try {
    # Build the parameter list for the sidecar script
    $sidecarArgs = @{
        'ConnectionString' = $ConnectionString
        'AkvKeyId' = $AkvKeyId
        'ScriptRoot' = (Get-Location).Path
        'CmkName' = $CmkName
    }
    
    if ($UseOnlineApproach) { 
        $sidecarArgs['UseOnlineApproach'] = $true
        $sidecarArgs['MaxDowntimeInSeconds'] = $MaxDowntimeInSeconds
    }
    
    if ($LogFileDirectory) {
        $sidecarArgs['LogFileDirectory'] = $LogFileDirectory
    }
    
    Write-Host "Parameters:" -ForegroundColor Gray
    foreach ($arg in $sidecarArgs.GetEnumerator()) {
        $value = if ($arg.Key -eq 'ConnectionString') { 
            $arg.Value -replace 'Password=[^;]+', 'Password=***' 
        } else { 
            $arg.Value 
        }
        Write-Host "  $($arg.Key) = $value" -ForegroundColor Gray
    }
    Write-Host ""
    
    # Execute the migration sidecar script
    & $MigrationScript @sidecarArgs
    
    Write-Host ""
    Write-Host "✅ Migration sidecar completed successfully!" -ForegroundColor Green
    
} catch {
    Write-Host "❌ Migration sidecar failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   Script: $MigrationScript" -ForegroundColor Gray
    exit 1
}

Write-Host ""
Write-Host "🎉 Always Encrypted migration deployment completed!" -ForegroundColor Magenta