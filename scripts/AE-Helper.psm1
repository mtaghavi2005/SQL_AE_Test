# AE-Helper.psm1
# Shared PowerShell module for Always Encrypted operations
# Contains all the enhanced logic for AAD auth, Key Vault, CMK/CEK management

function Invoke-AlwaysEncryptedMigration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $ConnectionString,
        [Parameter(Mandatory=$true)] [string] $KeyVaultName,
        [Parameter(Mandatory=$false)] [array]  $AeTargets = @(),   # AE targets from model (only AE columns)
        [Parameter(Mandatory=$false)] [string] $DbSchema = $null,  # Optional schema filter
        [string] $CmkName = 'CMK_App',
        [switch] $UseOnlineApproach,
        [int] $MaxDowntimeInSeconds = 180,
        [string] $LogFileDirectory = $null
    )

    Write-Host "AE deployment from EF Core model" -ForegroundColor Cyan
    Write-Host "   DbSchema: $($DbSchema ?? 'ALL')" -ForegroundColor Gray

    Import-Module SqlServer -MinimumVersion 22.0.50
    Import-Module Az.Accounts -ErrorAction SilentlyContinue
    Import-Module Az.KeyVault -ErrorAction SilentlyContinue

    # Helper: normalize encryption type for comparison (NOT for Set-SqlColumnEncryption)
    function Normalize-EncTypeForCompare {
        param([string] $Type)
        if ([string]::IsNullOrWhiteSpace($Type)) { return 'PLAIN' }
        $u = $Type.ToUpperInvariant()
        switch ($u) {
            'PLAINTEXT' { return 'PLAIN' }
            'PLAIN'     { return 'PLAIN' }
            default     { return $u }  # DETERMINISTIC / RANDOMIZED
        }
    }

    # Azure KV token and DB connection
    $keyVaultAccessToken = (Get-AzAccessToken -ResourceUrl "https://vault.azure.net").Token
    $db = Get-SqlDatabase -ConnectionString $ConnectionString

    # Build AKV key URL from KeyVaultName and CmkName
    # Azure Key Vault doesn't support underscores in key names, so replace them with hyphens
    $akvKeyName = $CmkName -replace '_', '-'
    $AkvKeyId = "https://${KeyVaultName}.vault.azure.net/keys/${akvKeyName}"
    
    Write-Host "🔑 Using Azure Key Vault: $KeyVaultName" -ForegroundColor Gray
    Write-Host "🔑 AKV Key Name: $akvKeyName" -ForegroundColor Gray
    Write-Host "🔑 CMK Name (in DB): $CmkName" -ForegroundColor Gray

    # Ensure AKV key exists
    $existingKey = Get-AzKeyVaultKey -VaultName $KeyVaultName -Name $akvKeyName -ErrorAction SilentlyContinue
    if ($existingKey) {
        $AkvKeyId = $existingKey.Id
        Write-Host "✅ Found existing AKV key: $AkvKeyId" -ForegroundColor Green
    } else {
        Write-Host "Creating new AKV key: $akvKeyName..." -ForegroundColor Yellow
        $newKey = Add-AzKeyVaultKey -VaultName $KeyVaultName -Name $akvKeyName -Destination Software -KeyType RSA -Size 2048
        $AkvKeyId = $newKey.Id
        Write-Host "✅ Created AKV key: $AkvKeyId" -ForegroundColor Green
    }

    # Ensure CMK (enclave-enabled)
    $cmkSettings = New-SqlAzureKeyVaultColumnMasterKeySettings -KeyUrl $AkvKeyId -AllowEnclaveComputations -KeyVaultAccessToken $keyVaultAccessToken
    if (-not (Get-SqlColumnMasterKey -InputObject $db | Where-Object Name -eq $CmkName)) {
        Write-Host "Creating CMK '$CmkName'..." -ForegroundColor Yellow
        New-SqlColumnMasterKey -InputObject $db -Name $CmkName -ColumnMasterKeySettings $cmkSettings | Out-Null
    }

    # Normalize AE targets from model (only AE columns, optional schema filter)
    Write-Host "📋 Normalizing AE targets from model..." -ForegroundColor Green
    $normalizedTargets = @()
    foreach ($t in $AeTargets) {
        if (-not $t) { continue }
        if ($DbSchema -and $t.Schema -ne $DbSchema) { continue }

        $encType = $null
        if     ($t.PSObject.Properties['EncryptionType']) { $encType = $t.EncryptionType }
        elseif ($t.PSObject.Properties['Type'])           { $encType = $t.Type }
        if ([string]::IsNullOrWhiteSpace($encType))       { $encType = 'Plain' }

        # We only keep actual AE columns here
        $normalizedEncType = Normalize-EncTypeForCompare $encType
        Write-Host "DEBUG: Column $($t.Schema).$($t.Table).$($t.Column) - Raw: '$encType' → Normalized: '$normalizedEncType'" -ForegroundColor DarkGray
        if ($normalizedEncType -eq 'PLAIN') { continue }

        $cekName = $null
        if     ($t.PSObject.Properties['CekName']) { $cekName = $t.CekName }
        elseif ($t.PSObject.Properties['Cek'])     { $cekName = $t.Cek }
        if ([string]::IsNullOrWhiteSpace($cekName)) {
            throw "AE target $($t.Schema).$($t.Table).$($t.Column) has encryption '$encType' but no CEK name."
        }

        $normalizedTargets += [pscustomobject]@{
            Schema         = $t.Schema
            Table          = $t.Table
            Column         = $t.Column
            EncryptionType = $encType       # 'Deterministic' / 'Randomized'
            CekName        = $cekName
        }
    }
    $AeTargets = $normalizedTargets
    Write-Host "   Model AE targets (encrypted columns only): $($AeTargets.Count)" -ForegroundColor Gray

    # Current encrypted columns from DB
    Write-Host "📊 Reading currently encrypted columns from database..." -ForegroundColor Green
    $schemaFilter = if ($DbSchema) { "AND s.name = '$DbSchema'" } else { "" }

    $currentEncryptedQuery = @"
SELECT
    s.name  AS SchemaName,
    t.name  AS TableName,
    c.name  AS ColumnName,
    c.encryption_type_desc AS EncryptionTypeDesc,
    cek.name AS CekName
FROM sys.columns c
JOIN sys.tables  t ON c.object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
LEFT JOIN sys.column_encryption_keys cek
    ON c.column_encryption_key_id = cek.column_encryption_key_id
WHERE c.encryption_type IS NOT NULL
$schemaFilter;
"@
    $currentEncryptedRows = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $currentEncryptedQuery
    Write-Host "   Currently encrypted columns in DB: $($currentEncryptedRows.Count)" -ForegroundColor Gray

    $currentMap = @{}
    foreach ($r in $currentEncryptedRows) {
        $key = "{0}.{1}.{2}" -f $r.SchemaName, $r.TableName, $r.ColumnName
        $currentMap[$key] = [pscustomobject]@{
            Schema         = $r.SchemaName
            Table          = $r.TableName
            Column         = $r.ColumnName
            EncryptionType = $r.EncryptionTypeDesc  # 'DETERMINISTIC' / 'RANDOMIZED'
            CekName        = $r.CekName
        }
    }

    $targetMap = @{}
    foreach ($t in $AeTargets) {
        $key = "{0}.{1}.{2}" -f $t.Schema, $t.Table, $t.Column
        $targetMap[$key] = $t
    }

    # Compute delta: toEncrypt, toReencrypt, toDecrypt
    Write-Host "🔍 Computing AE delta..." -ForegroundColor Green
    $toEncrypt   = @()
    $toReencrypt = @()
    $toDecrypt   = @()

    # Encrypt / re-encrypt (in model)
    foreach ($key in $targetMap.Keys) {
        $desired = $targetMap[$key]
        $current = $currentMap[$key]

        if (-not $current) {
            $toEncrypt += $desired
            continue
        }

        $desiredType = Normalize-EncTypeForCompare $desired.EncryptionType
        $currentType = Normalize-EncTypeForCompare $current.EncryptionType

        $sameType = ($desiredType -eq $currentType)
        $sameCek  = ($desired.CekName -eq $current.CekName)

        if (-not ($sameType -and $sameCek)) {
            $toReencrypt += $desired
        }
    }

    # Decrypt (encrypted in DB but no longer in model)
    foreach ($key in $currentMap.Keys) {
        if (-not $targetMap.ContainsKey($key)) {
            $toDecrypt += $currentMap[$key]
        }
    }

    Write-Host "   Columns to encrypt   : $($toEncrypt.Count)"   -ForegroundColor Gray
    Write-Host "   Columns to reencrypt : $($toReencrypt.Count)" -ForegroundColor Gray
    Write-Host "   Columns to decrypt   : $($toDecrypt.Count)"   -ForegroundColor Gray

    if ($toEncrypt.Count -eq 0 -and $toReencrypt.Count -eq 0 -and $toDecrypt.Count -eq 0) {
        Write-Host "✅ No AE changes required. DB AE state already matches model." -ForegroundColor Green
        return
    }

    # Ensure CEKs for columns that need encrypt/re-encrypt
    Write-Host "🔐 Ensuring CEKs exist for AE delta columns..." -ForegroundColor Green
    $cekNamesToUse = @()

    foreach ($col in $toEncrypt) {
        if ($col.CekName -and -not ($cekNamesToUse -contains $col.CekName)) {
            $cekNamesToUse += $col.CekName
        }
    }
    foreach ($col in $toReencrypt) {
        if ($col.CekName -and -not ($cekNamesToUse -contains $col.CekName)) {
            $cekNamesToUse += $col.CekName
        }
    }

    $cekNamesToUse = $cekNamesToUse | Sort-Object -Unique
    Write-Host "   CEKs to ensure: $($cekNamesToUse -join ', ')" -ForegroundColor Gray

    foreach ($cekName in $cekNamesToUse) {
        if (-not (Get-SqlColumnEncryptionKey -InputObject $db | Where-Object Name -eq $cekName)) {
            Write-Host "Creating CEK: $cekName..." -ForegroundColor Yellow
            New-SqlColumnEncryptionKey -InputObject $db -Name $cekName -ColumnMasterKeyName $CmkName -KeyVaultAccessToken $keyVaultAccessToken | Out-Null
            Write-Host "✅ CEK '$cekName' created" -ForegroundColor Green
        } else {
            Write-Host "✅ CEK '$cekName' already exists" -ForegroundColor Green
        }
    }

    # Build ColumnEncryptionSettings for the delta only
    Write-Host "🛡️ Building ColumnEncryptionSettings for delta..." -ForegroundColor Green
    $ces = @()

    # Encrypt / Re-encrypt
    foreach ($t in @($toEncrypt + $toReencrypt)) {
        $fq = "$($t.Schema).$($t.Table).$($t.Column)"
        
        $ces += New-SqlColumnEncryptionSettings -ColumnName $fq -EncryptionType $t.EncryptionType -EncryptionKey $t.CekName

        Write-Host "   [AE]   $fq → $($t.EncryptionType) (CEK: $($t.CekName))" -ForegroundColor Gray
    }

    # Decrypt
    foreach ($t in $toDecrypt) {
        $fq = "$($t.Schema).$($t.Table).$($t.Column)"

        $ces += New-SqlColumnEncryptionSettings `
            -ColumnName     $fq `
            -EncryptionType PlainText

        Write-Host "   [PLAIN] $fq → PlainText (decrypt)" -ForegroundColor Gray
    }

    if (-not $ces -or $ces.Count -eq 0) {
        Write-Host "⚠️ No ColumnEncryptionSettings created after delta. Skipping Set-SqlColumnEncryption." -ForegroundColor Yellow
        return
    }

    $setArgs = @{ 
        InputObject              = $db
        ColumnEncryptionSettings = $ces
        KeyVaultAccessToken      = $keyVaultAccessToken
    }

    if ($PSBoundParameters.ContainsKey('LogFileDirectory') -and $LogFileDirectory) { 
        if (-not (Test-Path $LogFileDirectory)) {
            New-Item -Path $LogFileDirectory -ItemType Directory -Force | Out-Null
        }
        $setArgs.LogFileDirectory = $LogFileDirectory 
    }

    if ($UseOnlineApproach) { 
        $setArgs.UseOnlineApproach    = $true
        $setArgs.MaxDowntimeInSeconds = $MaxDowntimeInSeconds
    }

    try {
        Write-Host "🚀 Executing Set-SqlColumnEncryption for delta columns..." -ForegroundColor Yellow
        Set-SqlColumnEncryption @setArgs
        Write-Host "✅ Applied Always Encrypted changes" -ForegroundColor Green
    } catch {
        Write-Host "❌ Column encryption failed: $($_.Exception.Message)" -ForegroundColor Red
        throw $_
    }

    Write-Host "🎉 Always Encrypted migration completed successfully!" -ForegroundColor Magenta
}


function Remove-OrphanedAlwaysEncryptedObjects {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $ConnectionString,
        [Parameter(Mandatory=$true)] [array] $CurrentAeTargets,
        [Parameter(Mandatory=$false)] [string] $SchemaName = $null,
        [switch] $WhatIf
    )

    Write-Host "🧹 Cleaning up orphaned CEKs and CMKs..." -ForegroundColor Cyan
    if ($SchemaName) {
        Write-Host "   Scope: Schema '$SchemaName' only" -ForegroundColor Gray
    }

    $db = Get-SqlDatabase -ConnectionString $ConnectionString

    # Extract CEK names that should be kept (from the model targets)
    $requiredCekNames = @()
    foreach ($target in $CurrentAeTargets) {
        if (-not $target) { continue }
        
        # Apply schema filter if specified
        if ($SchemaName -and $target.Schema -ne $SchemaName) { continue }
        
        # Get CEK name from target
        $cekName = $null
        if     ($target.PSObject.Properties['CekName']) { $cekName = $target.CekName }
        
        if ($cekName -and -not ($requiredCekNames -contains $cekName)) {
            $requiredCekNames += $cekName
        }
    }
    
    Write-Host "   CEKs required by model: $($requiredCekNames -join ', ')" -ForegroundColor Gray

    # Get CEKs that are actually used in the specified schema
    $schemaFilter = if ($SchemaName) { "AND s.name = '$SchemaName'" } else { "" }
    
    $schemaCeksQuery = @"
SELECT DISTINCT cek.name AS ColumnEncryptionKeyName
FROM sys.columns c
INNER JOIN sys.column_encryption_keys cek ON c.column_encryption_key_id = cek.column_encryption_key_id
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE c.encryption_type IS NOT NULL
$schemaFilter
"@
    $schemaCeks = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $schemaCeksQuery
    $schemaCekNames = if ($schemaCeks) { $schemaCeks | ForEach-Object { $_.ColumnEncryptionKeyName } } else { @() }
    
    $schemaDisplay = if ($SchemaName) { "schema '$SchemaName'" } else { "all schemas" }
    Write-Host "   CEKs currently used in $schemaDisplay : $($schemaCekNames -join ', ')" -ForegroundColor Gray

    # Track what we're removing for summary
    $removedCeks = @()
    $removedCmks = @()

    # Remove CEKs that are in this schema but not required by the model
    $allCeks = Get-SqlColumnEncryptionKey -InputObject $db
    $orphanedCeks = $allCeks | Where-Object { 
        ($_.Name -in $schemaCekNames) -and ($_.Name -notin $requiredCekNames)
    }

    foreach ($cek in $orphanedCeks) {
        if ($WhatIf) {
            Write-Host "Would remove orphaned CEK: $($cek.Name)" -ForegroundColor Yellow
        } else {
            Write-Host "Removing orphaned CEK: $($cek.Name)" -ForegroundColor Gray
            Remove-SqlColumnEncryptionKey -InputObject $db -Name $cek.Name
            $removedCeks += $cek.Name
            Write-Host "✅ Removed CEK: $($cek.Name)" -ForegroundColor Green
        }
    }

    # Remove unused CMKs (only if they have NO CEKs at all, across all schemas)
    $allCmks = Get-SqlColumnMasterKey -InputObject $db
    $allRemainingCeks = Get-SqlColumnEncryptionKey -InputObject $db
    
    # Query database directly for CMKs that have CEKs
    $usedCmksQuery = @"
SELECT DISTINCT cmk.name AS ColumnMasterKeyName
FROM sys.column_master_keys cmk
INNER JOIN sys.column_encryption_key_values cekv ON cmk.column_master_key_id = cekv.column_master_key_id
INNER JOIN sys.column_encryption_keys cek ON cekv.column_encryption_key_id = cek.column_encryption_key_id
"@
    $usedCmksResult = Invoke-Sqlcmd -ConnectionString $ConnectionString -Query $usedCmksQuery
    $usedCmkNames = if ($usedCmksResult) { $usedCmksResult | ForEach-Object { $_.ColumnMasterKeyName } } else { @() }
    
    Write-Host "   CMKs currently in use: $($usedCmkNames -join ', ')" -ForegroundColor Gray
    
    $orphanedCmks = $allCmks | Where-Object { $_.Name -notin $usedCmkNames }

    foreach ($cmk in $orphanedCmks) {
        if ($WhatIf) {
            Write-Host "Would remove orphaned CMK: $($cmk.Name)" -ForegroundColor Yellow
        } else {
            try {
                Write-Host "Removing orphaned CMK: $($cmk.Name)" -ForegroundColor Gray
                Remove-SqlColumnMasterKey -InputObject $db -Name $cmk.Name
                $removedCmks += $cmk.Name
                Write-Host "✅ Removed CMK: $($cmk.Name)" -ForegroundColor Green
            } catch {
                Write-Host "⚠️  Cannot remove CMK '$($cmk.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "🎉 Cleanup complete!" -ForegroundColor Magenta
    if ($removedCeks.Count -gt 0) {
        Write-Host "   Removed CEKs: $($removedCeks.Count) ($($removedCeks -join ', '))" -ForegroundColor Gray
    } else {
        Write-Host "   Removed CEKs: 0" -ForegroundColor Gray
    }
    if ($removedCmks.Count -gt 0) {
        Write-Host "   Removed CMKs: $($removedCmks.Count) ($($removedCmks -join ', '))" -ForegroundColor Gray
    } else {
        Write-Host "   Removed CMKs: 0" -ForegroundColor Gray
    }
}

# Export the functions
Export-ModuleMember -Function Invoke-AlwaysEncryptedMigration, Remove-OrphanedAlwaysEncryptedObjects
