#!/usr/bin/env pwsh
# Simple local test runner that loads environment variables and calls the deployment script

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

Write-Host ""
Write-Host "🚀 Running Always Encrypted deployment..." -ForegroundColor Cyan
Write-Host ""

# Call the deployment script (environment variables will be picked up automatically)
& (Join-Path $PSScriptRoot "run-ae-deployment.ps1")