using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace SQL_AE_Test.Data.Infrastructure
{
    public static class AeColumnTargetDiscovery
    {
        public static IReadOnlyList<AeColumnTarget> FromModel(IModel model)
        {
            ArgumentNullException.ThrowIfNull(model);

            var relationalModel = model.GetRelationalModel();

            return relationalModel.Tables
                .SelectMany(table =>
                {
                    var schema = table.Schema ?? "dbo";
                    var tableName = table.Name;

                    return table.Columns
                        .Select(column => ResolveEncryptionMetadata(column, schema, tableName))
                        .Where(target => target != null)
                        .OfType<AeColumnTarget>();
                })
                .OrderBy(r => r.Schema, StringComparer.OrdinalIgnoreCase)
                .ThenBy(r => r.Table, StringComparer.OrdinalIgnoreCase)
                .ThenBy(r => r.Column, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }

        private static AeColumnTarget? ResolveEncryptionMetadata(IColumn column, string schema, string tableName)
        {
            var propertyWithAe = column.PropertyMappings
                .Select(pm => pm.Property)
                .FirstOrDefault(p => p.FindAnnotation(AeAnnotationNames.Type) != null);

            if (propertyWithAe == null)
            {
                return null;
            }

            var typeAnnotation = propertyWithAe.FindAnnotation(AeAnnotationNames.Type)?.Value as string;
            var cekAnnotation = propertyWithAe.FindAnnotation(AeAnnotationNames.CEK);
            var cekName = cekAnnotation?.Value as string;

            return new AeColumnTarget
            {
                Schema = schema,
                Table = tableName,
                Column = column.Name,
                EncryptionType = typeAnnotation ?? string.Empty,
                CekName = string.IsNullOrWhiteSpace(cekName) ? null : cekName
            };
        }
    }
}