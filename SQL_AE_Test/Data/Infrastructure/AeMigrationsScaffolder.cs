// File: Infrastructure/AeMigrationsScaffolder.cs
// Target: EF Core 6+
// Registers in DesignTimeServices:
// services.AddSingleton<IMigrationsScaffolder>(sp =>
//     new AeMigrationsScaffolder(
//         inner: ActivatorUtilities.CreateInstance<MigrationsScaffolder>(sp),
//         differ: sp.GetRequiredService<IMigrationsModelDiffer>(),
//         migrationsAssembly: sp.GetRequiredService<IMigrationsAssembly>(),
//         current: sp.GetRequiredService<ICurrentDbContext>()));

using System.Text;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Migrations.Design;
using Microsoft.EntityFrameworkCore.Migrations.Operations;

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

        private static List<AeTarget> CollectAeTargetsFromDiffs(
            IReadOnlyList<MigrationOperation> ops,
            IModel currentModel)
        {
            var list = new List<AeTarget>();
            Console.WriteLine($"[CollectAeTargetsFromDiffs] Processing {ops.Count} operations:");
            
            foreach (var op in ops)
            {
                Console.WriteLine($"[CollectAeTargetsFromDiffs] Operation type: {op.GetType().Name}");
                switch (op)
                {
                    case CreateTableOperation create:
                    {
                        Console.WriteLine($"[CollectAeTargetsFromDiffs] CreateTableOperation for table: {create.Name}, columns: {create.Columns.Count}");
                        foreach (var col in create.Columns)
                        {
                            var found = TryResolveAeForColumn(create.Schema ?? "dbo", create.Name!, col.Name, currentModel);
                            if (found != null) {
                                Console.WriteLine($"[CollectAeTargetsFromDiffs] Found AE target for column: {col.Name}");
                                list.Add(found.Value);
                            }
                        }
                        break;
                    }
                    case AddColumnOperation add:
                    {
                        var found = TryResolveAeForColumn(add.Schema ?? "dbo", add.Table!, add.Name, currentModel);
                        if (found != null) list.Add(found.Value);
                        break;
                    }
                    case AlterColumnOperation alt:
                    {
                        var found = TryResolveAeForColumn(alt.Schema ?? "dbo", alt.Table!, alt.Name, currentModel);
                        if (found != null) list.Add(found.Value);
                        break;
                    }
                    // You can extend here for RenameColumnOperation if you want to emit hints/logs.
                }
            }


            // De-dup if both Add+Alter touch same column within the same diff batch
            return list
                .GroupBy(t => (t.Schema, t.Table, t.Column), new AeTargetKeyComparer())
                .Select(g => g.Last())
                .ToList();
        }

        private static AeTarget? TryResolveAeForColumn(string schema, string table, string columnName, IModel model)
        {
            Console.WriteLine($"[TryResolveAeForColumn] Looking for AE annotations on {schema}.{table}.{columnName}");
            
            // Find entity types mapped to the table
            foreach (var et in model.GetEntityTypes()
                         .Where(e => (e.GetSchema() ?? "dbo").Equals(schema, StringComparison.OrdinalIgnoreCase)
                                     && (e.GetTableName() ?? "").Equals(table, StringComparison.OrdinalIgnoreCase)))
            {
                var soi = StoreObjectIdentifier.Table(table, schema);
                foreach (var p in et.GetProperties())
                {
                    var col = p.GetColumnName(soi);
                    if (!string.Equals(col, columnName, StringComparison.OrdinalIgnoreCase))
                        continue;

                    var type = p.FindAnnotation(AeAnnotationNames.Type)?.Value?.ToString();
                    var cek = p.FindAnnotation(AeAnnotationNames.CEK)?.Value?.ToString();
                    Console.WriteLine($"[TryResolveAeForColumn] Column {columnName}: type='{type}', cek='{cek}'");
                    
                    if (!string.IsNullOrWhiteSpace(type) && !string.IsNullOrWhiteSpace(cek))
                    {
                        // Normalize type to the values expected by Set-SqlColumnEncryption (Deterministic|Randomized)
                        var normType = string.Equals(type, "Deterministic", StringComparison.OrdinalIgnoreCase)
                            ? "Deterministic"
                            : "Randomized";

                        Console.WriteLine($"[TryResolveAeForColumn] Found AE target: {schema}.{table}.{columnName} -> {normType}, {cek}");
                        return new AeTarget(schema, table, columnName, normType, cek);
                    }
                }
            }

            return null;
        }

        private static string GeneratePowerShell(string migrationId, List<AeTarget> targets)
        {
            var sb = new StringBuilder();

            sb.AppendLine(@"param(
  [Parameter(Mandatory=$true)] [string] $ConnectionString,
  [Parameter(Mandatory=$true)] [string] $AkvKeyId,
  [Parameter(Mandatory=$true)] [string] $ScriptRoot,
  [string] $CmkName = 'CMK_App',
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
                sb.AppendLine($"  @{{ Schema = '{t.Schema}'; Table = '{t.Table}'; Column = '{t.Column}'; Type = '{t.Type}'; Cek = '{t.Cek}' }}");
            }

            sb.AppendLine(@")

# Call the shared AE function with all parameters
$params = @{
  ConnectionString = $ConnectionString
  AkvKeyId = $AkvKeyId
  MigrationId = '" + migrationId + @"'
  AeTargets = $aeTargets
  CmkName = $CmkName
}

if ($UseOnlineApproach) { $params.UseOnlineApproach = $true }
if ($MaxDowntimeInSeconds -ne 180) { $params.MaxDowntimeInSeconds = $MaxDowntimeInSeconds }
if ($LogFileDirectory) { $params.LogFileDirectory = $LogFileDirectory }

Invoke-AlwaysEncryptedMigration @params");

            return sb.ToString();
        }

        private readonly record struct AeTarget(string Schema, string Table, string Column, string Type, string Cek);

        // public MigrationFiles Save(ScaffoldedMigration scaffoldedMigration, string projectDir)
        // {
        //     Console.WriteLine($"[AeMigrationsScaffolder] Save called for migration: {scaffoldedMigration.MigrationId}");
        //     
        //     // Let EF write the migration files first
        //     var files = _inner.Save(projectDir, scaffoldedMigration, outputDir: null);
        //
        //     // Compute differences snapshot -> current model
        //     var snapshotModel = _migrationsAssembly.ModelSnapshot?.Model;
        //     var currentModel = _current.Context.Model;
        //
        //     var diffs = _differ.GetDifferences(
        //         snapshotModel?.GetRelationalModel(),
        //         currentModel.GetRelationalModel());
        //
        //     // Extract AE-annotated columns BY RESOLVING THEM FROM THE CURRENT MODEL
        //     var targets = CollectAeTargetsFromDiffs(diffs, currentModel);
        //     Console.WriteLine($"[AeMigrationsScaffolder] Found {targets.Count} AE targets");
        //     
        //     if (targets.Count == 0)
        //         return files;
        //
        //     // Generate PS content and write next to migration .cs
        //     var folder = Path.GetDirectoryName(files.MigrationFile) ?? ".";
        //     var psPath = Path.Combine(folder, $"{scaffoldedMigration.MigrationId}_AE.ps1");
        //     File.WriteAllText(psPath, GeneratePowerShell(scaffoldedMigration.MigrationId, targets));
        //     Console.WriteLine($"[AeMigrationsScaffolder] PowerShell sidecar written to: {psPath}");
        //
        //     return files;
        // }

        public ScaffoldedMigration ScaffoldMigration(
            string migrationName,
            string? rootNamespace,
            string? subNamespace = null,
            string? language = null,
            bool dryRun = false)
        {
            Console.WriteLine($"[AeMigrationsScaffolder] Scaffolding migration: {migrationName}");
            var scaffoldedMigration = _inner.ScaffoldMigration(migrationName, rootNamespace, subNamespace, language, dryRun);
            
            if (!dryRun)
            {
                // Generate PowerShell sidecar file - this will be handled by the Save method when EF calls it
                Console.WriteLine($"[AeMigrationsScaffolder] Migration scaffolded: {migrationName}");
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
            Console.WriteLine($"[AeMigrationsScaffolder] Save (overload 2) called for migration: {migration.MigrationId}, dryRun: {dryRun}");
            
            // Delegate to the default scaffolder first
            var files = _inner.Save(projectDir, migration, outputDir, dryRun);
            Console.WriteLine($"[AeMigrationsScaffolder] Default scaffolder completed");

            // Only emit sidecar when not a dry-run (and we have a concrete migration path)
            if (dryRun) {
                Console.WriteLine("[AeMigrationsScaffolder] Dry run, skipping PowerShell generation");
                return files;
            }

            try 
            {
                // Get models (prefer design-time model to avoid read-optimized issues)
                var snapshotModel = _migrationsAssembly.ModelSnapshot?.Model;
                var designTimeModel = _current.Context.GetService<IDesignTimeModel>();
                var currentModel = designTimeModel.Model;

                Console.WriteLine("[AeMigrationsScaffolder] Computing model differences...");
                var diffs = _differ.GetDifferences(
                    snapshotModel?.GetRelationalModel(),
                    currentModel.GetRelationalModel());

                Console.WriteLine($"[AeMigrationsScaffolder] Found {diffs.Count} differences, collecting AE targets from ops...");
                var targetsFromOps = CollectAeTargetsFromDiffs(diffs, currentModel);
                Console.WriteLine($"[AeMigrationsScaffolder] Found {targetsFromOps.Count} AE targets from ops diff");
                
                Console.WriteLine($"[AeMigrationsScaffolder] Found {diffs.Count} differences, collecting AE targets from model...");
                var targetsFromModel = CollectAeTargetsFromModel(currentModel);
                Console.WriteLine($"[AeMigrationsScaffolder] Found {targetsFromModel.Count} AE targets from model");
                
                var allTargets = targetsFromOps.Concat(targetsFromModel)
                    .GroupBy(t => (t.Schema, t.Table, t.Column), new AeTargetKeyComparer())
                    .Select(g => g.Last())
                    .ToList();
                
                if (allTargets.Count == 0) return files;

                // Find where the migration file was saved; write sidecar next to it
                var migrationFile = files.MigrationFile;
                var folder = Path.GetDirectoryName(migrationFile) ?? outputDir ?? projectDir ?? ".";
                var sidecarPath = Path.Combine(folder, $"{migration.MigrationId}_AE.ps1");

                Console.WriteLine($"[AeMigrationsScaffolder] Writing PowerShell sidecar to: {sidecarPath}");
                File.WriteAllText(sidecarPath, GeneratePowerShell(migration.MigrationId, allTargets));
                Console.WriteLine("[AeMigrationsScaffolder] PowerShell sidecar written successfully!");
                
                return files;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[AeMigrationsScaffolder] ERROR generating PowerShell sidecar: {ex.Message}");
                Console.WriteLine($"[AeMigrationsScaffolder] Stack trace: {ex.StackTrace}");
                return files;
            }
        }

        // --------------------------------------------------------------------------------------
        // Helpers
        // --------------------------------------------------------------------------------------

        private static List<AeTarget> CollectAeTargetsFromModel(IModel model)
        {
            var result = new List<AeTarget>();
            Console.WriteLine($"[AeMigrationsScaffolder] CollectAeTargetsFromModel: Processing {model.GetEntityTypes().Count()} entity types");

            foreach (var et in model.GetEntityTypes())
            {
                Console.WriteLine($"[AeMigrationsScaffolder] Processing entity: {et.Name}");
                var schema = et.GetSchema() ?? "dbo";
                var table  = et.GetTableName();
                Console.WriteLine($"[AeMigrationsScaffolder] Entity {et.Name}: schema='{schema}', table='{table}'");
                if (string.IsNullOrEmpty(table)) continue;

                var soi = StoreObjectIdentifier.Table(table, schema);

                foreach (var p in et.GetProperties())
                {
                    Console.WriteLine($"[AeMigrationsScaffolder] Processing property: {p.Name}");
                    
                    // Check if this property has AE annotations
                    var hasAeType = p.GetAnnotations().Any(a => a.Name == "AE:Type");
                    var hasAeCek = p.GetAnnotations().Any(a => a.Name == "AE:CekName");
                    Console.WriteLine($"[AeMigrationsScaffolder] Property {p.Name}: hasAeType={hasAeType}, hasAeCek={hasAeCek}");
                    
                    if (!hasAeType || !hasAeCek) continue;
                    
                    var colName = p.GetColumnName(soi);
                    Console.WriteLine($"[AeMigrationsScaffolder] Property {p.Name}: colName='{colName}'");
                    
                    // Fallback to property name if GetColumnName returns empty
                    if (string.IsNullOrEmpty(colName)) 
                    {
                        colName = p.Name;
                        Console.WriteLine($"[AeMigrationsScaffolder] Property {p.Name}: Using property name as column name: '{colName}'");
                    }

                    var type = p.FindAnnotation("AE:Type")?.Value?.ToString();
                    var cek  = p.FindAnnotation("AE:CekName")?.Value?.ToString();
                    Console.WriteLine($"[AeMigrationsScaffolder] Property {p.Name}: Found AE - type={type}, cek={cek}");
                    if (string.IsNullOrWhiteSpace(type) || string.IsNullOrWhiteSpace(cek)) 
                    {
                        Console.WriteLine($"[AeMigrationsScaffolder] Property {p.Name}: Skipping - empty type or cek");
                        continue;
                    }

                    var normType = string.Equals(type, "Deterministic", StringComparison.OrdinalIgnoreCase)
                        ? "Deterministic"
                        : "Randomized";

                    Console.WriteLine($"[AeMigrationsScaffolder] Property {p.Name}: Adding AE target - schema={schema}, table={table}, column={colName}, type={normType}, cek={cek}");
                    result.Add(new AeTarget(schema, table, colName, normType, cek!));
                }
            }

            Console.WriteLine($"[AeMigrationsScaffolder] CollectAeTargetsFromModel: Returning {result.Count} targets");
            return result;
        }

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