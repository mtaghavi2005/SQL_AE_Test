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
# Or save to file
dotnet run --project SQL_AE_Test/SQL_AE_Test.csproj -- ae-dump-targets --output targets.json
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
    "EncryptionType": "PlainText",
    "CekName": null
  }
]
```

This JSON feeds the deployment pipeline and guarantees that encryption, decryption, and cleanup match the latest model snapshot.

### Model-Based Deployment Script

`scripts/run-ae-model-deployment.ps1` performs idempotent Always Encrypted deployment:

1. Loads AE targets from a JSON file.
2. Imports `AE-Helper.psm1`.
3. Ensures enclave-enabled Column Master Key (CMK) and Column Encryption Keys (CEKs) exist in Azure SQL (backed by Azure Key Vault).
4. Applies encryption or decryption for each mapped column based on the JSON targets.
5. (Optional) Runs cleanup to remove orphaned CEKs and CMKs for the specified schema.

The helper module provisions CMKs with `AllowEnclaveComputations`, creates CEKs using Azure Key Vault tokens. Azure Key Vault key names use hyphens instead of underscores (e.g., `CMK_App` → `CMK-App`).

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
   KEY_VAULT_NAME=your-vault-name
   AE_CMK_NAME=CMK_App
   DB_SCHEMA=dbo

   ```

   **Note**: `KEY_VAULT_NAME` is just the vault name (e.g., `mt-sql-ae-test-kv`), not the full URL.

## 🔁 Workflow

1. **Model Changes**: Decorate properties with `[AlwaysEncrypted]` or remove the attribute as requirements change.
2. **Migrations**: Create EF migrations as usual (`dotnet ef migrations add ...`). Only schema SQL is required—AE configuration is now model-driven.
3. **Deploy Schema**: Apply EF migrations to your database (`dotnet ef database update` or migration bundle).
4. **Deploy Always Encrypted**:
   - Local testing: `pwsh scripts/run-ae-local-deployment.ps1 -ProjectPath './SQL_AE_Test/SQL_AE_Test.csproj'`
   - With cleanup: `pwsh scripts/run-ae-local-deployment.ps1 -ProjectPath './SQL_AE_Test/SQL_AE_Test.csproj' -Clean`
   - CI/CD: 
     ```bash
     # Generate targets JSON
     dotnet run --project SQL_AE_Test/SQL_AE_Test.csproj -- ae-dump-targets --output targets.json
     # Deploy with the JSON file
     pwsh scripts/run-ae-model-deployment.ps1 -ConnectionString $env:SQL_CONNECTION_STRING -KeyVaultName $env:KEY_VAULT_NAME -CmkName $env:AE_CMK_NAME -AeTargetsJsonFile 'targets.json' -DbSchema 'dbo' -Cleanup
     ```

### Migration JSON Sidecars

- `AeMigrationsScaffolder` generates `*.json` files next to each EF migration containing AE targets.
- Each sidecar reflects the model state at migration creation time.
- Use for history tracking or rollback scenarios.

The deployment script is safe to rerun. It encrypts columns that require protection, decrypts columns that became plain, and (when `-Cleanup` is specified) removes unused CEKs and CMKs.

## 🛠️ PowerShell Usage

```powershell
# Direct invocation with JSON file
pwsh scripts/run-ae-model-deployment.ps1 \
    -ConnectionString 'sql-connection-string' \
    -KeyVaultName 'your-vault-name' \
    -CmkName 'CMK_App' \
    -AeTargetsJsonFile 'targets.json' \
    -DbSchema 'dbo' \
    -UseOnlineApproach \
    -MaxDowntimeInSeconds 180 \
    -Cleanup
```

**Key Naming Convention:**
- Use `CMK_{Schema}_{Purpose}` for schema-isolated microservices
- Examples: `CMK_DBO_App`, `CMK_Orders_App`, `CMK_Inventory_App`
- The same name is used for both the database CMK metadata and the Azure Key Vault key
- Supports underscores `_` and hyphens `-` in names

The script logs progress and cleanup output shows removed CEKs and CMKs.

## 📚 Additional Resources

- [Always Encrypted with secure enclaves](https://learn.microsoft.com/sql/relational-databases/security/encryption/always-encrypted-enclaves)
- [Create a column master key stored in Azure Key Vault](https://learn.microsoft.com/sql/relational-databases/security/encryption/create-and-store-column-master-keys-always-encrypted)
- [Entity Framework Core documentation](https://learn.microsoft.com/ef/core/)
