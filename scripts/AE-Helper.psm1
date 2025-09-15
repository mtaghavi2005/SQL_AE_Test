# AE-Helper.psm1
# Shared PowerShell module for Always Encrypted operations
# Contains all the enhanced logic for AAD auth, Key Vault, CMK/CEK management

function Invoke-AlwaysEncryptedMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $ConnectionString,
        [Parameter(Mandatory=$true)] [string] $AkvKeyId,
        [Parameter(Mandatory=$true)] [string] $MigrationId,
        [Parameter(Mandatory=$true)] [array] $AeTargets,
        [string] $CmkName = 'CMK_App',
        [switch] $UseOnlineApproach,
        [int] $MaxDowntimeInSeconds = 180,
        [string] $LogFileDirectory = $null
    )

    # Import required modules
    Import-Module SqlServer -MinimumVersion 22.0.50
    Import-Module Az.Accounts -ErrorAction SilentlyContinue
    Import-Module Az.KeyVault -ErrorAction SilentlyContinue

    Write-Host "AE sidecar for migration: $MigrationId" -ForegroundColor Cyan

    # Get Azure Key Vault access token for authentication
    $keyVaultAccessToken = $null
    try {
        $keyVaultAccessToken = (Get-AzAccessToken -ResourceUrl https://vault.azure.net).Token
        Write-Host "Azure Key Vault access token obtained successfully" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to get Azure Key Vault access token. Ensure you're authenticated with Connect-AzAccount"
        throw $_
    }

    # Connect to SQL Database using connection string
    $db = $null
    try {
        Write-Host "Using provided connection string for database authentication..."
        $db = Get-SqlDatabase -ConnectionString $ConnectionString
        Write-Host "Connected to database successfully" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to connect with connection string: $($_.Exception.Message)"
        throw "Could not establish database connection with the provided connection string"
    }

    # Debug output
    if ($db) {
        Write-Host "Database object type: $($db.GetType().FullName)"
        Write-Host "Database name: $($db.Name)"
    } else {
        Write-Host "ERROR: Database connection failed - db object is null" -ForegroundColor Red
        throw "Could not establish database connection"
    }

    # Parse Key Vault details from AkvKeyId URL
    $keyUrlParts = $AkvKeyId -split '/'
    $vaultName = $keyUrlParts[2] -replace '\.vault\.azure\.net', ''
    $keyName = $keyUrlParts[4]

    Write-Host "Key Vault Details:" -ForegroundColor Yellow
    Write-Host "  Vault Name: $vaultName" -ForegroundColor Gray
    Write-Host "  Key Name: $keyName" -ForegroundColor Gray
    Write-Host "  Full Key URL: $AkvKeyId" -ForegroundColor Gray

    # Ensure the key exists in Azure Key Vault
    Write-Host ""
    Write-Host "🔑 Ensuring Key Vault key exists..." -ForegroundColor Green
    try {
        $existingKey = Get-AzKeyVaultKey -VaultName $vaultName -Name $keyName -ErrorAction SilentlyContinue
        if ($existingKey) {
            Write-Host "✅ Key '$keyName' already exists in Key Vault '$vaultName'" -ForegroundColor Green
            Write-Host "   Key ID: $($existingKey.Id)" -ForegroundColor Gray
            # Update AkvKeyId to use the specific version
            $AkvKeyId = $existingKey.Id
        } else {
            Write-Host "⚠️  Key '$keyName' not found. Creating new RSA key..." -ForegroundColor Yellow
            $newKey = Add-AzKeyVaultKey -VaultName $vaultName -Name $keyName -Destination Software -KeyType RSA -Size 2048
            if ($newKey) {
                Write-Host "✅ Key '$keyName' created successfully!" -ForegroundColor Green
                Write-Host "   Key ID: $($newKey.Id)" -ForegroundColor Gray
                $AkvKeyId = $newKey.Id
            } else {
                throw "Failed to create key in Key Vault"
            }
        }
    } catch {
        Write-Host "❌ Failed to create Key Vault key: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Message -like "*Forbidden*" -or $_.Exception.Message -like "*not authorized*") {
            Write-Host ""
            Write-Host "🔧 Permission Issue - Key Creation Failed:" -ForegroundColor Yellow
            Write-Host "   You need 'Key Vault Contributor' or 'Key Vault Crypto Officer' role to create keys" -ForegroundColor Gray
            Write-Host ""
            Write-Host "Manual key creation command:" -ForegroundColor Cyan
            Write-Host "   az keyvault key create --vault-name '$vaultName' --name '$keyName' --kty RSA --size 2048" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "⚠️  Continuing with provided key URL (key must exist for CEK creation to work)" -ForegroundColor Yellow
            Write-Host "   Key URL: $AkvKeyId" -ForegroundColor Gray
        } else {
            # For non-permission errors, still fail
            throw $_
        }
    }

    # Ensure Column Master Key (AKV-backed)
    Write-Host ""
    Write-Host "🔐 Managing Column Master Key in SQL Database..." -ForegroundColor Green
    $cmkSettings = New-SqlAzureKeyVaultColumnMasterKeySettings -KeyUrl $AkvKeyId
    if (-not (Get-SqlColumnMasterKey -InputObject $db | Where-Object Name -eq $CmkName)) {
        Write-Host "Creating Column Master Key: $CmkName with AKV key: $AkvKeyId"
        New-SqlColumnMasterKey -InputObject $db -Name $CmkName -ColumnMasterKeySettings $cmkSettings | Out-Null
        Write-Host "✅ Column Master Key created successfully" -ForegroundColor Green
    } else {
        Write-Host "✅ Column Master Key '$CmkName' already exists" -ForegroundColor Green
    }

    # Create Column Encryption Keys
    Write-Host ""
    Write-Host "🔐 Managing Column Encryption Keys..." -ForegroundColor Green

    # Extract distinct CEKs from targets and ensure they exist
    $distinctCeks = $AeTargets | ForEach-Object { $_.Cek } | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique
    foreach ($cekName in $distinctCeks) {
        if (-not (Get-SqlColumnEncryptionKey -InputObject $db | Where-Object Name -eq $cekName)) {
            Write-Host "Creating Column Encryption Key: $cekName..." -ForegroundColor Yellow
            try {
                New-SqlColumnEncryptionKey -InputObject $db -Name $cekName -ColumnMasterKeyName $CmkName -KeyVaultAccessToken $keyVaultAccessToken | Out-Null
                Write-Host "✅ Column Encryption Key '$cekName' created successfully" -ForegroundColor Green
            } catch {
                Write-Host "❌ Failed to create CEK '$cekName': $($_.Exception.Message)" -ForegroundColor Red
                throw $_
            }
        } else {
            Write-Host "✅ Column Encryption Key '$cekName' already exists" -ForegroundColor Green
        }
    }

    # Apply Column Encryption Settings
    Write-Host ""
    Write-Host "🛡️ Applying column encryption..." -ForegroundColor Green

    # Handle AE column targets
    if ($AeTargets.Count -eq 0) {
        Write-Host 'No AE column targets in this migration.' -ForegroundColor Yellow
        Write-Host "Completed AE sidecar (migration $MigrationId)" -ForegroundColor Magenta
        return
    }

    # Create column encryption settings
    $ces = @()
    foreach ($target in $AeTargets) {
        $fqColumnName = "$($target.Schema).$($target.Table).$($target.Column)"
        $ces += New-SqlColumnEncryptionSettings -ColumnName $fqColumnName -EncryptionType $target.Type -EncryptionKey $target.Cek
    }

    Write-Host "Column encryption settings:" -ForegroundColor Gray
    foreach ($setting in $ces) {
        Write-Host "  $($setting.ColumnName) -> $($setting.EncryptionType) ($($setting.EncryptionKey))" -ForegroundColor Gray
    }

    $setArgs = @{ 
        InputObject = $db
        ColumnEncryptionSettings = $ces
        KeyVaultAccessToken = $keyVaultAccessToken
    }

    if ($PSBoundParameters.ContainsKey('LogFileDirectory') -and $LogFileDirectory) { 
        # Create log directory if it doesn't exist
        if (-not (Test-Path $LogFileDirectory)) {
            New-Item -Path $LogFileDirectory -ItemType Directory -Force | Out-Null
            Write-Host "Created log directory: $LogFileDirectory" -ForegroundColor Gray
        }
        $setArgs.LogFileDirectory = $LogFileDirectory 
        Write-Host "Logging to: $LogFileDirectory" -ForegroundColor Gray
    }

    if ($UseOnlineApproach) { 
        $setArgs.UseOnlineApproach = $true
        $setArgs.MaxDowntimeInSeconds = $MaxDowntimeInSeconds
        Write-Host "Using online approach (max downtime: $MaxDowntimeInSeconds seconds)" -ForegroundColor Gray
    }

    try {
        Write-Host "Executing Set-SqlColumnEncryption..." -ForegroundColor Yellow
        Set-SqlColumnEncryption @setArgs
        Write-Host "✅ Applied Always Encrypted for migration $MigrationId" -ForegroundColor Green
    } catch {
        Write-Host "❌ Column encryption failed: $($_.Exception.Message)" -ForegroundColor Red
        throw $_
    }

    Write-Host ""
    Write-Host "🎉 Always Encrypted migration completed successfully!" -ForegroundColor Magenta
}

# Export the function
Export-ModuleMember -Function Invoke-AlwaysEncryptedMigration