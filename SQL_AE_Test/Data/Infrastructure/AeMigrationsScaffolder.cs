// File: Infrastructure/AeMigrationsScaffolder.cs
// Target: EF Core 6+
// Registers in DesignTimeServices:
// services.AddSingleton<IMigrationsScaffolder>(sp =>
//     new AeMigrationsScaffolder(
//         inner: ActivatorUtilities.CreateInstance<MigrationsScaffolder>(sp),
//         differ: sp.GetRequiredService<IMigrationsModelDiffer>(),
//         migrationsAssembly: sp.GetRequiredService<IMigrationsAssembly>(),
//         current: sp.GetRequiredService<ICurrentDbContext>()));

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Migrations.Design;
using Microsoft.Extensions.DependencyInjection;

namespace SQL_AE_Test.Data.Infrastructure
{
    /// <summary>
    /// Wraps EF Core's scaffolder to emit a PowerShell sidecar per migration that applies Always Encrypted.
    /// Reads AE data from the CURRENT model (annotations added by your convention), not from migration ops.
    /// </summary>
    public sealed class AeMigrationsScaffolder : IMigrationsScaffolder
    {
        private readonly IMigrationsScaffolder _inner;
        private readonly IMigrationsModelDiffer _differ;
        private readonly IMigrationsAssembly _migrationsAssembly;
        private readonly ICurrentDbContext _current;

        public AeMigrationsScaffolder(
            IMigrationsScaffolder inner,
            IMigrationsModelDiffer differ,
            IMigrationsAssembly migrationsAssembly,
            ICurrentDbContext current)
        {
            _inner = inner ?? throw new ArgumentNullException(nameof(inner));
            _differ = differ ?? throw new ArgumentNullException(nameof(differ));
            _migrationsAssembly = migrationsAssembly ?? throw new ArgumentNullException(nameof(migrationsAssembly));
            _current = current ?? throw new ArgumentNullException(nameof(current));
        }

        // ---- Helpers -------------------------------------------------------------------------

        private static void WriteDebug(string message)
        {
            // Only output debug messages when EF verbosity is enabled
            // You can also check for environment variables like EF_VERBOSE or dotnet ef --verbose
            if (Environment.GetEnvironmentVariable("EF_VERBOSE") == "1" || 
                Environment.GetEnvironmentVariable("DOTNET_EF_VERBOSE") == "1")
            {
                Console.WriteLine($"[AeMigrationsScaffolder] {message}");
            }
        }

        private static string GeneratePowerShell(string migrationId, IReadOnlyList<AeColumnTarget> targets)
        {
            var sb = new StringBuilder();

            sb.AppendLine(@"param(
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
$aeTargets = @(");

            foreach (var t in targets)
            {
                var cekValue = string.IsNullOrWhiteSpace(t.CekName) ? "$null" : $"'{t.CekName}'";
                sb.AppendLine($"  @{{ Schema = '{t.Schema}'; Table = '{t.Table}'; Column = '{t.Column}'; EncryptionType = '{t.EncryptionType}'; CekName = {cekValue} }}");
            }

            sb.AppendLine(@")

# Call the shared AE function with all parameters
$params = @{
  ConnectionString = $ConnectionString
  AkvKeyId = $AkvKeyId
  MigrationId = '" + migrationId + @"'
  CmkName = $CmkName
}

# Add AeTargets only if not empty to avoid parameter binding issues
if ($aeTargets.Count -gt 0) {
  $params.AeTargets = $aeTargets
}

if ($UseOnlineApproach) { $params.UseOnlineApproach = $true }
if ($MaxDowntimeInSeconds -ne 180) { $params.MaxDowntimeInSeconds = $MaxDowntimeInSeconds }
if ($LogFileDirectory) { $params.LogFileDirectory = $LogFileDirectory }

Invoke-AlwaysEncryptedMigration @params

Remove-OrphanedAlwaysEncryptedObjects -ConnectionString $ConnectionString -CurrentAeTargets $aeTargets");

            return sb.ToString();
        }

        public ScaffoldedMigration ScaffoldMigration(
            string migrationName,
            string? rootNamespace,
            string? subNamespace = null,
            string? language = null,
            bool dryRun = false)
        {
            WriteDebug($"Scaffolding migration: {migrationName}");
            var scaffoldedMigration = _inner.ScaffoldMigration(migrationName, rootNamespace, subNamespace, language, dryRun);
            
            if (!dryRun)
            {
                WriteDebug($"Migration scaffolded: {migrationName}");
            }
            
            return scaffoldedMigration;
        }

        public MigrationFiles RemoveMigration(
            string projectDir,
            string? rootNamespace,
            bool force,
            string? language,
            bool dryRun = false)
        {
            // Delegate removal to default scaffolder
            var files = _inner.RemoveMigration(projectDir, rootNamespace, force, language, dryRun);

            // Try to delete the sidecar that matches the removed migration (best-effort)
            if (!dryRun)
            {
                TryDeleteSidecarNextTo(files.MigrationFile);
            }

            return files;
        }

        public MigrationFiles Save(
            string projectDir,
            ScaffoldedMigration migration,
            string? outputDir,
            bool dryRun = false)
        {
            WriteDebug($"Save called for migration: {migration.MigrationId}, dryRun: {dryRun}");
            
            // Delegate to the default scaffolder first
            var files = _inner.Save(projectDir, migration, outputDir, dryRun);
            WriteDebug("Default scaffolder completed");

            // Only emit sidecar when not a dry-run (and we have a concrete migration path)
            if (dryRun) {
                WriteDebug("Dry run, skipping PowerShell generation");
                return files;
            }

            try 
            {
                // Get models (prefer design-time model to avoid read-optimized issues)
                var snapshotModel = _migrationsAssembly.ModelSnapshot?.Model;
                var designTimeModel = _current.Context.GetService<IDesignTimeModel>();
                var currentModel = designTimeModel?.Model ?? snapshotModel ?? _current.Context.Model;

                // For AE configuration, we only care about the current model state (desired final state)
                // Not the migration operations - the cleanup system handles the differences
                WriteDebug("Collecting AE targets from current model...");
                var columnTargets = AeColumnTargetDiscovery.FromModel(currentModel);
                WriteDebug($"Found {columnTargets.Count} AE targets from model");
                
                // Always generate PowerShell sidecar (even with no targets) to ensure cleanup runs
                // Find where the migration file was saved; write sidecar next to it
                var migrationFile = files.MigrationFile;
                var folder = Path.GetDirectoryName(migrationFile) ?? outputDir ?? projectDir ?? ".";
                var sidecarPath = Path.Combine(folder, $"{migration.MigrationId}_AE.ps1");

                WriteDebug($"Writing PowerShell sidecar to: {sidecarPath} (with {columnTargets.Count} AE targets)");
                File.WriteAllText(sidecarPath, GeneratePowerShell(migration.MigrationId, columnTargets));
                WriteDebug("PowerShell sidecar written successfully!");
                
                return files;
            }
            catch (Exception ex)
            {
                WriteDebug($"ERROR generating PowerShell sidecar: {ex.Message}");
                WriteDebug($"Stack trace: {ex.StackTrace}");
                return files;
            }
        }

        // --------------------------------------------------------------------------------------
        // Helpers
        // --------------------------------------------------------------------------------------

        private static void TryDeleteSidecarNextTo(string? migrationFilePath)
        {
            if (string.IsNullOrWhiteSpace(migrationFilePath)) return;

            try
            {
                var dir = Path.GetDirectoryName(migrationFilePath);
                if (dir is null) return;

                var migrationBase = Path.GetFileNameWithoutExtension(migrationFilePath); // e.g., 20250907123456_AddX
                var sidecar = Path.Combine(dir, $"{migrationBase}_AE.ps1");
                if (File.Exists(sidecar))
                {
                    File.Delete(sidecar);
                }
                else
                {
                    // Fallback: if MigrationId differs from filename base, try scanning for *_AE.ps1 with same timestamp prefix
                    var prefix = migrationBase.Split('_').FirstOrDefault();
                    if (!string.IsNullOrWhiteSpace(prefix))
                    {
                        var candidates = Directory.GetFiles(dir, $"{prefix}_*_AE.ps1");
                        foreach (var c in candidates) File.Delete(c);
                    }
                }
            }
            catch
            {
                // best-effort; ignore failures (source control cleanup will catch it)
            }
        }
    }
}