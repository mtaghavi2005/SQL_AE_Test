#!/usr/bin/env pwsh
# Simple local runner that loads environment variables and executes the model-based deployment

Write-Host "🧪 Loading environment variables from .env..." -ForegroundColor Cyan

# Load environment variables from .env file (in project root)
$envFile = Join-Path (Split-Path $PSScriptRoot -Parent) ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match "^([^#][^=]+)=(.*)$") {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
            Write-Host "  $name = $value" -ForegroundColor Gray
        }
    }
    Write-Host "✅ Environment variables loaded" -ForegroundColor Green
} else {
    Write-Host "❌ .env file not found at: $envFile" -ForegroundColor Red
    exit 1
}

$connectionString = $env:SQL_CONNECTION_STRING
$akvKeyId = $env:AKV_KEY_ID
$cmkName = $env:AE_CMK_NAME

if ([string]::IsNullOrWhiteSpace($connectionString) -or
    [string]::IsNullOrWhiteSpace($akvKeyId) -or
    [string]::IsNullOrWhiteSpace($cmkName)) {
    Write-Host "❌ Missing required environment variables: SQL_CONNECTION_STRING, AKV_KEY_ID, AE_CMK_NAME" -ForegroundColor Red
    exit 1
}

$arguments = @{
    ConnectionString = $connectionString
    AkvKeyId = $akvKeyId
    CmkName = $cmkName
}

if ($env:AE_LOG_DIR) {
    $arguments.LogFileDirectory = $env:AE_LOG_DIR
}

if ($env:AE_USE_ONLINE -and $env:AE_USE_ONLINE.ToLowerInvariant() -in @('1','true','yes')) {
    $arguments.UseOnlineApproach = $true
    if ($env:AE_MAX_DOWNTIME) {
        [int]$parsedMaxDowntime = 0
        if ([int]::TryParse($env:AE_MAX_DOWNTIME, [ref]$parsedMaxDowntime)) {
            $arguments.MaxDowntimeInSeconds = $parsedMaxDowntime
        }
    }
}

if ($env:AE_CLEANUP -and $env:AE_CLEANUP.ToLowerInvariant() -in @('1','true','yes')) {
    $arguments.Cleanup = $true
}

Write-Host ""
Write-Host "🚀 Running model-based Always Encrypted deployment..." -ForegroundColor Cyan
Write-Host ""

& (Join-Path $PSScriptRoot "run-ae-model-deployment.ps1") @arguments
