# SQL Always Encrypted Test Project

This project demonstrates Entity Framework Core integration with SQL Server Always Encrypted using Azure Key Vault. It features a custom migration scaffolder that automatically generates PowerShell scripts to configure Always Encrypted settings.

## 🏗️ Project Structure

```
SQL_AE_Test/
├── .env                           # Environment variables for local testing
├── README.md                      # This file
├── SQL_AE_Test.sln               # Visual Studio solution
├── scripts/                       # PowerShell automation scripts
│   ├── AE-Helper.psm1            # Shared PowerShell module for AE operations
│   ├── run-ae-local-deployment.ps1  # Local test runner (loads .env and calls run-ae-deployment)
│   └── run-ae-deployment.ps1     # Main AE deployment script
├── docs/                         # Documentation
│   └── AZURE_DEVOPS_SETUP.md    # Azure DevOps pipeline setup
└── SQL_AE_Test/                  # Main project
    ├── Program.cs                # Console application entry point
    ├── appsettings.json         # Application configuration
    ├── Models/
    │   └── Customer.cs          # Domain model with AE attributes
    ├── Data/
    │   ├── AppDbContext.cs      # Entity Framework context
    │   └── Infrastructure/      # Custom AE scaffolding infrastructure
    └── Migrations/              # EF migrations and AE scripts
        └── *_AE.ps1             # Generated AE sidecar scripts per migration
```

## 🔐 Always Encrypted Architecture

### Custom Migration Scaffolder

The project includes a custom `AeMigrationsScaffolder` that automatically:

1. **Detects AE Columns**: Scans for properties marked with `[AlwaysEncrypted]` attributes
2. **Generates Sidecar Scripts**: Creates `.ps1` files alongside each migration
3. **Modular Design**: Uses a shared `AE-Helper.psm1` module to avoid code duplication

### AE Attribute System

Mark properties for encryption using the custom attribute:

```csharp
[AlwaysEncrypted(AeEncryptionType.Deterministic, cekName: "CEK_PII")]
public required string SSN { get; set; }

[AlwaysEncrypted(AeEncryptionType.Randomized, cekName: "CEK_PII")]
public DateTime? BirthDate { get; set; }
```

### Generated Script Structure

Each migration generates a clean, minimal `.AE.ps1` script:

```powershell
param(
  [Parameter(Mandatory=$true)] [string] $ConnectionString,
  [Parameter(Mandatory=$true)] [string] $AkvKeyId,
  [string] $CmkName = 'CMK_App',
  # ... other parameters
)

# Import shared AE module
Import-Module (Join-Path $PSScriptRoot 'AE-Helper.psm1') -Force

# Define AE targets for this migration
$aeTargets = @(
  @{ Schema = 'dbo'; Table = 'Customers'; Column = 'SSN'; Type = 'Deterministic'; Cek = 'CEK_PII' }
  # ... more targets
)

# Call shared AE function
Invoke-AlwaysEncryptedMigration @params
```

## 🚀 Getting Started

### Prerequisites

- .NET 9.0 SDK
- PowerShell 7+ with modules:
  - `SqlServer` (v22.0.50+)
  - `Az.Accounts`
  - `Az.KeyVault`
- SQL Server with Always Encrypted support
- Azure Key Vault access

### Setup

1. **Clone and Build**:
   ```bash
   git clone <repository-url>
   cd SQL_AE_Test
   dotnet build
   ```

2. **Configure Environment**:
   ```bash
   # Copy and edit .env file
   cp .env.example .env
   # Edit .env with your actual values
   ```

3. **Environment Variables** (`.env`):
   ```properties
   SQL_CONNECTION_STRING=Server=tcp:your-server.database.windows.net,1433;Initial Catalog=YourDB;User ID=user;Password=pass;Encrypt=True;
   AKV_KEY_ID=https://your-vault.vault.azure.net/keys/your-key
   AE_CMK_NAME=CMK_App
   AE_MIGRATION_SCRIPT=  # Optional: specific script path
   ```

### Usage

#### 1. Generate Migration with AE Script

```bash
# Navigate to project directory
cd SQL_AE_Test

# Add migration (automatically generates _AE.ps1 sidecar)
dotnet ef migrations add AddEncryptedColumns
```

#### 2. Apply Database Schema

```bash
# Apply EF migration to database
dotnet ef database update
```

#### 3. Configure Always Encrypted

```bash
# Option A: Use simple test runner
```bash
pwsh scripts/run-ae-local-deployment.ps1
```

### Deployment Scripts

#### `run-ae-local-deployment.ps1`
- Loads environment variables from `.env`
- Calls `run-ae-deployment.ps1` with loaded configuration
- Ideal for local development and testing

#### `run-ae-deployment.ps1`  
- Finds and executes the latest migration sidecar script
- Supports both environment variables and direct parameters
- Provides detailed execution feedback and error handling
- Can target specific migration scripts

### Migration Workflow

1. **Model Changes**: Add/modify properties with `[AlwaysEncrypted]` attributes
2. **Generate Migration**: `dotnet ef migrations add MigrationName`
3. **Review Files**: Check generated `.cs` migration and `_AE.ps1` sidecar
4. **Apply Schema**: `dotnet ef database update`  
5. **Configure AE**: Run the generated `_AE.ps1` script

## 📚 Additional Resources

- [SQL Server Always Encrypted Documentation](https://docs.microsoft.com/en-us/sql/relational-databases/security/encryption/always-encrypted-database-engine)
- [Azure Key Vault Integration](https://docs.microsoft.com/en-us/sql/relational-databases/security/encryption/create-and-store-column-master-keys-always-encrypted)
- [Entity Framework Core Documentation](https://docs.microsoft.com/en-us/ef/core/)