# AE-Helper.psm1
# Shared PowerShell module for Always Encrypted operations
# Contains all the enhanced logic for AAD auth, Key Vault, CMK/CEK management

function Invoke-AlwaysEncryptedMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $ConnectionString,
        [Parameter(Mandatory=$true)] [string] $AkvKeyId,
        [Parameter(Mandatory=$false)] [string] $MigrationId = 'CurrentModelDeployment',
        [Parameter(Mandatory=$false)] [array] $AeTargets = @(),  # Allow empty arrays
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
        $keyVaultAccessToken = (Get-AzAccessToken -ResourceUrl "https://vault.azure.net").Token
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

    # Validate database connection
    if (-not $db) {
        throw "Could not establish database connection"
    }

    # Parse Key Vault details from AkvKeyId URL
    $keyUrlParts = $AkvKeyId -split '/'
    $vaultName = $keyUrlParts[2] -replace '\.vault\.azure\.net', ''
    $keyName = $keyUrlParts[4]



    # Ensure the key exists in Azure Key Vault
    Write-Host ""
    Write-Host "🔑 Ensuring Key Vault key exists..." -ForegroundColor Green
    try {
        $existingKey = Get-AzKeyVaultKey -VaultName $vaultName -Name $keyName -ErrorAction SilentlyContinue
        if ($existingKey) {
            Write-Host "✅ Key '$keyName' already exists in Key Vault '$vaultName'" -ForegroundColor Green
            # Update AkvKeyId to use the specific version
            $AkvKeyId = $existingKey.Id
        } else {
            Write-Host "⚠️  Key '$keyName' not found. Creating new RSA key..." -ForegroundColor Yellow
            $newKey = Add-AzKeyVaultKey -VaultName $vaultName -Name $keyName -Destination Software -KeyType RSA -Size 2048
            if ($newKey) {
                Write-Host "✅ Key '$keyName' created successfully!" -ForegroundColor Green
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
    $cmkSettings = New-SqlAzureKeyVaultColumnMasterKeySettings -KeyUrl $AkvKeyId -AllowEnclaveComputations -KeyVaultAccessToken $keyVaultAccessToken
    if (-not (Get-SqlColumnMasterKey -InputObject $db | Where-Object Name -eq $CmkName)) {
        Write-Host "Creating Column Master Key: $CmkName with AKV key: $AkvKeyId"
        New-SqlColumnMasterKey -InputObject $db -Name $CmkName -ColumnMasterKeySettings $cmkSettings | Out-Null
        Write-Host "✅ Column Master Key created successfully" -ForegroundColor Green
    } else {
        Write-Host "✅ Column Master Key '$CmkName' already exists" -ForegroundColor Green
    }

    try {
        $cmkStatus = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query "SELECT enclave_computations_enabled FROM sys.column_master_keys WHERE name = '$CmkName'"
        if ($cmkStatus -and $cmkStatus[0].enclave_computations_enabled -eq 1) {
            Write-Host "🛡️  Enclave computations are enabled for CMK '$CmkName'" -ForegroundColor Green
        } else {
            throw "CMK '$CmkName' is not configured for enclave computations. Please provision or update the CMK to allow enclave computations before rerunning."
        }
    } catch {
        throw "Unable to verify enclave configuration for CMK '$CmkName': $($_.Exception.Message)"
    }

    # Create Column Encryption Keys
    Write-Host ""
    Write-Host "🔐 Managing Column Encryption Keys..." -ForegroundColor Green

    # Normalize AE targets to a consistent shape
    $normalizedTargets = @()
    foreach ($target in $AeTargets) {
        if (-not $target) { continue }
        $encryptionType = $null
        if ($target.PSObject.Properties['EncryptionType']) {
            $encryptionType = $target.EncryptionType
        } elseif ($target.PSObject.Properties['Type']) {
            $encryptionType = $target.Type
        }
        if ([string]::IsNullOrWhiteSpace($encryptionType)) {
            $encryptionType = 'Plain'
        }
        $cekName = $null
        if ($target.PSObject.Properties['CekName']) {
            $cekName = $target.CekName
        } elseif ($target.PSObject.Properties['Cek']) {
            $cekName = $target.Cek
        }
        if ([string]::IsNullOrWhiteSpace($cekName)) {
            $cekName = $null
        }
        $normalizedTargets += [pscustomobject]@{
            Schema = $target.Schema
            Table = $target.Table
            Column = $target.Column
            EncryptionType = $encryptionType
            CekName = $cekName
        }
    }
    $AeTargets = $normalizedTargets

    # Extract distinct CEKs from targets and ensure they exist
    $distinctCeks = $AeTargets | Where-Object { $_.EncryptionType -ne 'Plain' -and $_.EncryptionType -ne 'PlainText' } | ForEach-Object { $_.CekName } | Where-Object { $_ -and $_.Trim() } | Sort-Object -Unique
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
        $targetEncryptionType = $target.EncryptionType
        if ($targetEncryptionType -eq 'Plain') {
            $targetEncryptionType = 'PlainText'
        }

        $settingsArgs = @{
            ColumnName = $fqColumnName
            EncryptionType = $targetEncryptionType
        }

        if ($targetEncryptionType -ne 'PlainText') {
            if (-not $target.CekName) {
                throw "Column $fqColumnName requires a CEK name for encryption type $targetEncryptionType"
            }
            $settingsArgs.EncryptionKey = $target.CekName
        }

        $ces += New-SqlColumnEncryptionSettings @settingsArgs
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
        }
        $setArgs.LogFileDirectory = $LogFileDirectory 
    }

    if ($UseOnlineApproach) { 
        $setArgs.UseOnlineApproach = $true
        $setArgs.MaxDowntimeInSeconds = $MaxDowntimeInSeconds
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

function Remove-OrphanedAlwaysEncryptedObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $ConnectionString,
        [Parameter(Mandatory=$false)] [array] $CurrentAeTargets = @(),  # Current AE targets from EF model (can be empty)
        [switch] $WhatIf
    )
    
    Write-Host "🧹 Cleaning up orphaned Always Encrypted objects..." -ForegroundColor Cyan
    
    # Connect to database
    $db = Get-SqlDatabase -ConnectionString $ConnectionString
    
    # Get all currently encrypted columns from database
    $encryptedColumnsQuery = @"
SELECT 
    s.name AS SchemaName,
    t.name AS TableName,
    c.name AS ColumnName,
    cek.name AS ColumnEncryptionKeyName,
    c.encryption_type_desc AS EncryptionType
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
LEFT JOIN sys.column_encryption_keys cek ON c.column_encryption_key_id = cek.column_encryption_key_id
WHERE c.encryption_type IS NOT NULL
"@
    
    $currentlyEncryptedColumns = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $encryptedColumnsQuery
    
    # Convert current AE targets to lookup set
    $desiredEncryptedColumns = @{}
    foreach ($target in $CurrentAeTargets) {
        $key = "$($target.Schema).$($target.Table).$($target.Column)"
        $desiredEncryptedColumns[$key] = $target
    }
    
    # Find columns that are encrypted in DB but not in current EF model
    $columnsToDecrypt = @()
    foreach ($col in $currentlyEncryptedColumns) {
        $key = "$($col.SchemaName).$($col.TableName).$($col.ColumnName)"
        if (-not $desiredEncryptedColumns.ContainsKey($key)) {
            $columnsToDecrypt += $col
        }
    }
    
    Write-Host ""
    Write-Host "📊 Cleanup Analysis:" -ForegroundColor Yellow
    Write-Host "  Currently encrypted columns in DB: $($currentlyEncryptedColumns.Count)" -ForegroundColor Gray
    Write-Host "  Desired encrypted columns from EF model: $($CurrentAeTargets.Count)" -ForegroundColor Gray
    Write-Host "  Columns to decrypt (no longer in EF model): $($columnsToDecrypt.Count)" -ForegroundColor Red
    
    if ($columnsToDecrypt.Count -gt 0) {
        Write-Host ""
        Write-Host "🔓 Columns to decrypt:" -ForegroundColor Red
        foreach ($col in $columnsToDecrypt) {
            Write-Host "  - $($col.SchemaName).$($col.TableName).$($col.ColumnName) (CEK: $($col.ColumnEncryptionKeyName))" -ForegroundColor Red
        }
    }
    
    if ($WhatIf) {
        Write-Host ""
        Write-Host "⚠️  WhatIf mode - no changes will be made" -ForegroundColor Yellow
        
        if ($columnsToDecrypt.Count -eq 0) {
            Write-Host "✅ No cleanup needed - all encrypted columns are in current EF model" -ForegroundColor Green
        }
        
        return $columnsToDecrypt
    }
    
    # Initialize results structure
    $decryptedColumns = @()
    $orphanedCeks = @()
    $orphanedCmks = @()
    
    # Only decrypt columns if there are any to decrypt
    if ($columnsToDecrypt.Count -gt 0) {
    
        # Get Key Vault access token for decryption
        $keyVaultAccessToken = $null
        try {
            $keyVaultAccessToken = (Get-AzAccessToken -ResourceUrl "https://vault.azure.net").Token
            Write-Host "✅ Azure Key Vault access token obtained" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to get Azure Key Vault access token. Decryption may fail."
        }
        
        # Decrypt orphaned columns
        Write-Host ""
        Write-Host "🔓 Removing encryption from orphaned columns..." -ForegroundColor Yellow
        
        $ces = @()
        foreach ($col in $columnsToDecrypt) {
            $fqColumnName = "$($col.SchemaName).$($col.TableName).$($col.ColumnName)"
            $ces += New-SqlColumnEncryptionSettings -ColumnName $fqColumnName -EncryptionType PlainText
            Write-Host "  Decrypting: $fqColumnName" -ForegroundColor Gray
        }
        
        $setArgs = @{ 
            InputObject = $db
            ColumnEncryptionSettings = $ces
        }
        
        if ($keyVaultAccessToken) {
            $setArgs.KeyVaultAccessToken = $keyVaultAccessToken
        }
        
        try {
            Set-SqlColumnEncryption @setArgs
            Write-Host "✅ Successfully decrypted $($columnsToDecrypt.Count) orphaned columns" -ForegroundColor Green
            $decryptedColumns = $columnsToDecrypt
        } catch {
            Write-Host "❌ Column decryption failed: $($_.Exception.Message)" -ForegroundColor Red
            throw $_
        }
    } else {
        Write-Host ""
        Write-Host "✅ No columns to decrypt - all encrypted columns match current EF model" -ForegroundColor Green
    }
    
    # Now clean up orphaned CEKs and CMKs
    Write-Host ""
    Write-Host "🗑️ Cleaning up orphaned CEKs and CMKs..." -ForegroundColor Yellow
    
    # Get currently used CEKs (from remaining encrypted columns)
    $usedCeksQuery = @"
SELECT DISTINCT cek.name AS ColumnEncryptionKeyName
FROM sys.columns c
INNER JOIN sys.column_encryption_keys cek ON c.column_encryption_key_id = cek.column_encryption_key_id
WHERE c.encryption_type IS NOT NULL
"@
    $usedCeks = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $usedCeksQuery
    $usedCekNames = if ($usedCeks) { $usedCeks | ForEach-Object { $_.ColumnEncryptionKeyName } } else { @() }
    
    # Remove orphaned CEKs
    $allCeks = Get-SqlColumnEncryptionKey -InputObject $db
    $orphanedCeks = $allCeks | Where-Object { $_.Name -notin $usedCekNames }
    
    $successfullyRemovedCeks = @()
    foreach ($cek in $orphanedCeks) {
        try {
            Write-Host "  Removing orphaned CEK: $($cek.Name)" -ForegroundColor Gray
            Remove-SqlColumnEncryptionKey -InputObject $db -Name $cek.Name
            Write-Host "  ✅ Removed CEK: $($cek.Name)" -ForegroundColor Green
            $successfullyRemovedCeks += $cek
        } catch {
            Write-Host "  ❌ Failed to remove CEK $($cek.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    # Update orphanedCeks to only include successfully removed ones
    $orphanedCeks = $successfullyRemovedCeks
    
    # Remove orphaned CMKs 
    # Strategy: If no columns are encrypted at all, remove ALL CMKs
    # Otherwise, only remove CMKs not referenced by any remaining CEKs
    $allCmks = Get-SqlColumnMasterKey -InputObject $db
    
    # Check if there are any encrypted columns remaining in the database
    $remainingEncryptedColumns = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $encryptedColumnsQuery
    
    if ($remainingEncryptedColumns.Count -eq 0 -and $CurrentAeTargets.Count -eq 0) {
        # No encrypted columns in DB and none desired from EF model - remove ALL CMKs
        Write-Host "  No encrypted columns remaining - removing ALL CMKs for complete cleanup" -ForegroundColor Yellow
        $orphanedCmks = $allCmks
    } else {
        # Standard cleanup - only remove CMKs not referenced by remaining CEKs
        # But first, check if we actually removed any CEKs - if not, don't remove CMKs either
        if ($successfullyRemovedCeks.Count -eq 0) {
            # No CEKs were removed, so don't attempt CMK removal
            Write-Host "  No CEKs removed - skipping CMK cleanup to preserve active keys" -ForegroundColor Gray
            $orphanedCmks = @()
        } else {
            # Some CEKs were removed - check which CMKs are still needed
            $remainingCeksAfterCleanup = Get-SqlColumnEncryptionKey -InputObject $db
            $usedCmkNames = $remainingCeksAfterCleanup | ForEach-Object { 
                # Get the CMK name through the Parent property or Name property
                if ($_.Parent -and $_.Parent.Name) { 
                    $_.Parent.Name 
                } else { 
                    # Fallback - query database for this specific CEK's CMK
                    $cmkQuery = "SELECT cmk.name FROM sys.column_encryption_keys cek JOIN sys.column_master_keys cmk ON cek.column_master_key_id = cmk.column_master_key_id WHERE cek.name = '$($_.Name)'"
                    $cmkResult = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $cmkQuery
                    if ($cmkResult) { $cmkResult.name } else { $null }
                }
            } | Where-Object { $_ } | Sort-Object -Unique
            $orphanedCmks = $allCmks | Where-Object { $_.Name -notin $usedCmkNames }
        }
    }
    
    $successfullyRemovedCmks = @()
    foreach ($cmk in $orphanedCmks) {
        try {
            Write-Host "  Removing orphaned CMK: $($cmk.Name)" -ForegroundColor Gray
            Remove-SqlColumnMasterKey -InputObject $db -Name $cmk.Name
            Write-Host "  ✅ Removed CMK: $($cmk.Name)" -ForegroundColor Green
            $successfullyRemovedCmks += $cmk
        } catch {
            Write-Host "  ❌ Failed to remove CMK $($cmk.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    # Update orphanedCmks to only include successfully removed ones
    $orphanedCmks = $successfullyRemovedCmks
    
    Write-Host ""
    Write-Host "🎉 Always Encrypted cleanup completed!" -ForegroundColor Magenta
    Write-Host "  Decrypted columns: $($decryptedColumns.Count)" -ForegroundColor Gray
    Write-Host "  Removed CEKs: $($orphanedCeks.Count)" -ForegroundColor Gray
    Write-Host "  Removed CMKs: $($orphanedCmks.Count)" -ForegroundColor Gray
    
    # Extract names as strings instead of objects
    $decryptedColumnNames = if ($decryptedColumns) { $decryptedColumns | ForEach-Object { "$($_.SchemaName).$($_.TableName).$($_.ColumnName)" } } else { @() }
    $removedCekNames = if ($orphanedCeks) { $orphanedCeks | ForEach-Object { $_.Name } } else { @() }
    $removedCmkNames = if ($orphanedCmks) { $orphanedCmks | ForEach-Object { $_.Name } } else { @() }
    
    return @{
        DecryptedColumns = $decryptedColumnNames
        RemovedCEKs = $removedCekNames
        RemovedCMKs = $removedCmkNames
    }
}

# Export the functions
Export-ModuleMember -Function Invoke-AlwaysEncryptedMigration, Remove-OrphanedAlwaysEncryptedObjects