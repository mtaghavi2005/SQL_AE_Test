param(
  [Parameter(Mandatory=$true)] [string] $Server,     # e.g. myserver.database.windows.net
  [Parameter(Mandatory=$true)] [string] $Database,   # e.g. MyDb
  [Parameter(Mandatory=$true)] [string] $AkvKeyId,   # https://<vault>.vault.azure.net/keys/<key>/<version>
  [string] $CmkName = 'CMK_App',
  [switch] $UseOnlineApproach,
  [int]    $MaxDowntimeInSeconds = 180,
  [string] $LogFileDirectory = $null
)

Import-Module SqlServer -MinimumVersion 22.0.50

# Connect with AAD Default (Managed Identity / SPN / Developer token)
$db = Get-SqlDatabase -ServerInstance "tcp:$Server,1433" -Name $Database

# Ensure Column Master Key (AKV-backed)
$cmkSettings = New-SqlAzureKeyVaultColumnMasterKeySettings -KeyUrl $AkvKeyId
if (-not (Get-SqlColumnMasterKey -InputObject $db | Where-Object Name -eq $CmkName)) {
  New-SqlColumnMasterKey -InputObject $db -Name $CmkName -ColumnMasterKeySettings $cmkSettings | Out-Null
}


if (-not (Get-SqlColumnEncryptionKey -InputObject $db | Where-Object Name -eq 'CEK_App')) {
  New-SqlColumnEncryptionKey -InputObject $db -Name 'CEK_App' -ColumnMasterKeyName $CmkName | Out-Null
}

if (-not (Get-SqlColumnEncryptionKey -InputObject $db | Where-Object Name -eq 'CEK_PII')) {
  New-SqlColumnEncryptionKey -InputObject $db -Name 'CEK_PII' -ColumnMasterKeyName $CmkName | Out-Null
}

$ces = @()

$ces += New-SqlColumnEncryptionSettings -ColumnName "dbo.Customers.BirthDate" -EncryptionType Randomized -EncryptionKey "CEK_App"
$ces += New-SqlColumnEncryptionSettings -ColumnName "dbo.Customers.SSN" -EncryptionType Deterministic -EncryptionKey "CEK_PII"

$setArgs = @{ InputObject = $db; ColumnEncryptionSettings = $ces }
if ($PSBoundParameters.ContainsKey('LogFileDirectory') -and $LogFileDirectory) { $setArgs.LogFileDirectory = $LogFileDirectory }
if ($UseOnlineApproach) { $setArgs.UseOnlineApproach = $true; $setArgs.MaxDowntimeInSeconds = $MaxDowntimeInSeconds }

Set-SqlColumnEncryption @setArgs
Write-Host "Applied Always Encrypted for migration 20250912102718_AddAEColumns"

