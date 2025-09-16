param(
  [Parameter(Mandatory=$true)] [string] $ConnectionString,
  [Parameter(Mandatory=$true)] [string] $AkvKeyId,
  [Parameter(Mandatory=$true)] [string] $ScriptRoot,
  [Parameter(Mandatory=$true)] [string] $CmkName,
  [switch] $UseOnlineApproach,
  [int] $MaxDowntimeInSeconds = 180,
  [string] $LogFileDirectory = $null
)

# Import the shared AE helper module from scripts folder
$moduleFile = Join-Path $ScriptRoot 'scripts' 'AE-Helper.psm1'
Import-Module $moduleFile -Force

# Convert targets to the format expected by the shared function
$aeTargets = @(
  @{ Schema = 'dbo'; Table = 'Customers'; Column = 'BirthDate'; Type = 'Randomized'; Cek = 'CEK_PII' }
  @{ Schema = 'dbo'; Table = 'Customers'; Column = 'SSN'; Type = 'Deterministic'; Cek = 'CEK_PII' }
)

# Call the shared AE function with all parameters
$params = @{
  ConnectionString = $ConnectionString
  AkvKeyId = $AkvKeyId
  MigrationId = '20250915113245_InitialCreateWithAlwaysEncrypted'
  AeTargets = $aeTargets
  CmkName = $CmkName
}

if ($UseOnlineApproach) { $params.UseOnlineApproach = $true }
if ($MaxDowntimeInSeconds -ne 180) { $params.MaxDowntimeInSeconds = $MaxDowntimeInSeconds }
if ($LogFileDirectory) { $params.LogFileDirectory = $LogFileDirectory }

Invoke-AlwaysEncryptedMigration @params

Remove-OrphanedAlwaysEncryptedObjects -ConnectionString $ConnectionString -CurrentAeTargets $aeTargets
