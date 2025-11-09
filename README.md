# SQL Always Encrypted Test Project

This project demonstrates Entity Framework Core integration with SQL Server Always Encrypted using Azure Key Vault. The solution now drives encryption entirely from the **current EF Core model**, ensuring schema and encryption stay in sync even across branches and long-lived deployments.

## 🏗️ Project Structure

```
SQL_AE_Test/
├── README.md                      # This file
├── SQL_AE_Test.sln                # Visual Studio solution
├── scripts/                       # PowerShell automation scripts
│   ├── AE-Helper.psm1             # Shared PowerShell module for AE operations
│   ├── run-ae-local-deployment.ps1# Local runner that loads .env and calls the model deployment script
│   └── run-ae-model-deployment.ps1# Model-driven AE deployment script
└── SQL_AE_Test/                   # Main project
    ├── Program.cs                # Console application / CLI entry point
    ├── appsettings.json          # Application configuration
    ├── Models/                   # Entity classes decorated with `[AlwaysEncrypted]`
    ├── Data/                     # EF Core context and AE infrastructure
    └── Migrations/               # EF migrations (schema only)
```

## 🔐 Always Encrypted Architecture

### Attribute-Based Model

Mark properties for encryption using the custom attribute:

```csharp
[AlwaysEncrypted(AeEncryptionType.Deterministic, cekName: "CEK_PII")]
public required string SSN { get; set; }

[AlwaysEncrypted(AeEncryptionType.Randomized, cekName: "CEK_PII")]
public DateTime? BirthDate { get; set; }
```

Every mapped column is discovered at runtime. If the attribute is removed the column will be decrypted automatically during the next deployment.

### AE Column Target Discovery

The console application exposes a CLI mode that emits the Always Encrypted targets represented in the EF model:

```bash
dotnet run --project SQL_AE_Test/SQL_AE_Test.csproj -- ae-dump-targets
```

Sample output:

```json
[
  {
    "Schema": "dbo",
    "Table": "Customers",
    "Column": "SSN",
    "EncryptionType": "Deterministic",
    "CekName": "CEK_PII"
  },
  {
    "Schema": "dbo",
    "Table": "Customers",
    "Column": "BirthDate",
    "EncryptionType": "Plain",
    "CekName": null
  }
]
```

This JSON feeds the deployment pipeline and guarantees that encryption, decryption, and cleanup match the latest model snapshot.

### Model-Based Deployment Script

`scripts/run-ae-model-deployment.ps1` performs idempotent Always Encrypted deployment:

1. Calls `ae-dump-targets` to gather the desired state.
2. Imports `AE-Helper.psm1`.
3. Ensures enclave-enabled Column Master Key (CMK) and Column Encryption Keys (CEKs) exist in Azure SQL (backed by Azure Key Vault).
4. Applies encryption or decryption for each mapped column based on the model output.
5. (Optional) Runs cleanup to remove orphaned encrypted columns or unused keys.

The helper module provisions CMKs with `AllowEnclaveComputations`, creates CEKs using Azure Key Vault tokens, and verifies `sys.column_master_keys.enclave_computations_enabled = 1` after provisioning.

## 🚀 Getting Started

### Prerequisites

- .NET 9.0 SDK
- PowerShell 7+
  - `SqlServer` (v22.0.50+)
  - `Az.Accounts`
  - `Az.KeyVault`
- Azure SQL Database with Always Encrypted secure enclaves enabled
- Azure Key Vault access for CMK/CEK operations

### Setup

1. **Clone and Build**
   ```bash
   git clone <repository-url>
   cd SQL_AE_Test
   dotnet build
   ```

2. **Configure Environment**
   Populate a `.env` file with connection information:
   ```properties
   SQL_CONNECTION_STRING=Server=tcp:your-server.database.windows.net,1433;Initial Catalog=YourDB;User ID=user;Password=pass;Encrypt=True;
   AKV_KEY_ID=https://your-vault.vault.azure.net/keys/your-key
   AE_CMK_NAME=CMK_App
   AE_LOG_DIR=./logs              # optional
   AE_USE_ONLINE=true             # optional
   AE_MAX_DOWNTIME=180            # optional, seconds
   AE_CLEANUP=true                # optional
   ```

## 🔁 Workflow

1. **Model Changes**: Decorate properties with `[AlwaysEncrypted]` or remove the attribute as requirements change.
2. **Migrations**: Create EF migrations as usual (`dotnet ef migrations add ...`). Only schema SQL is required—AE configuration is now model-driven.
3. **Deploy Schema**: Apply EF migrations to your database (`dotnet ef database update` or migration bundle).
4. **Deploy Always Encrypted**:
   - Local testing: `pwsh scripts/run-ae-local-deployment.ps1`
   - CI/CD: invoke `scripts/run-ae-model-deployment.ps1` with the required parameters.

### Per-Migration PowerShell Sidecars

- `AeMigrationsScaffolder` still generates `*_AE.ps1` sidecars next to every EF migration.
- Each sidecar now leverages the same model-driven discovery logic as the deployment script, ensuring history files always reflect the latest desired encryption state.
- During development you can rerun a specific sidecar to restore encryption for that migration or compare the generated targets between commits.

The deployment script is safe to rerun. It encrypts columns that require protection, decrypts columns that became plain, and (when `-Cleanup` is specified) removes unused CEKs and CMKs.

## 🛠️ PowerShell Usage

```powershell
# Direct invocation
pwsh scripts/run-ae-model-deployment.ps1 \
    -ConnectionString $env:SQL_CONNECTION_STRING \
    -AkvKeyId $env:AKV_KEY_ID \
    -CmkName $env:AE_CMK_NAME \
    -UseOnlineApproach \
    -MaxDowntimeInSeconds 180 \
    -Cleanup
```

The script logs progress, including verification that the CMK supports enclave computations. Cleanup output lists decrypted columns and removed keys.

## 📚 Additional Resources

- [Always Encrypted with secure enclaves](https://learn.microsoft.com/sql/relational-databases/security/encryption/always-encrypted-enclaves)
- [Create a column master key stored in Azure Key Vault](https://learn.microsoft.com/sql/relational-databases/security/encryption/create-and-store-column-master-keys-always-encrypted)
- [Entity Framework Core documentation](https://learn.microsoft.com/ef/core/)
