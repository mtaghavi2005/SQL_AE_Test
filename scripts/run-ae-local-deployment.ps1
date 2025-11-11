
#!/usr/bin/env pwsh
# Loads environment variables, requires ProjectPath, generates AE targets JSON, and calls run-ae-model-deployment.ps1

param(
    [Parameter(Mandatory=$true)] [string] $ProjectPath,
    [switch] $Clean
)

Write-Host "🧪 Loading environment variables from .env..." -ForegroundColor Cyan
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
$keyVaultName = $env:KEY_VAULT_NAME
$cmkName = $env:AE_CMK_NAME
$dbSchema = $env:DB_SCHEMA

if ([string]::IsNullOrWhiteSpace($connectionString) -or
    [string]::IsNullOrWhiteSpace($keyVaultName) -or
    [string]::IsNullOrWhiteSpace($cmkName) -or
    [string]::IsNullOrWhiteSpace($dbSchema)) {
    Write-Host "❌ Missing required environment variables: SQL_CONNECTION_STRING, KEY_VAULT_NAME, AE_CMK_NAME, DB_SCHEMA" -ForegroundColor Red
    exit 1
}

# Generate AE targets JSON from EF Core model
$aeTargetsJsonFile = "./ae-targets.json"
Write-Host "📤 Discovering Always Encrypted targets from EF Core model..." -ForegroundColor Green
$dotnetArgs = @('run', '--project', $ProjectPath, '--', 'ae-dump-targets', '--output', $aeTargetsJsonFile)
$output = & dotnet @dotnetArgs
if ($LASTEXITCODE -ne 0) {
    throw "dotnet run failed while gathering AE targets (exit code $LASTEXITCODE). Output: $output"
}
if (-not (Test-Path $aeTargetsJsonFile)) {
    throw "AE targets JSON file was not created."
}

# Prepare arguments for deployment
$arguments = @{
    ConnectionString = $connectionString
    KeyVaultName = $keyVaultName
    CmkName = $cmkName
    AeTargetsJsonFile = $aeTargetsJsonFile
    DbSchema = $dbSchema
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

if ($Clean) {
    $arguments.Cleanup = $true
}

Write-Host ""
Write-Host "🚀 Running model-based Always Encrypted deployment..." -ForegroundColor Cyan
Write-Host ""
& (Join-Path $PSScriptRoot "run-ae-model-deployment.ps1") @arguments
