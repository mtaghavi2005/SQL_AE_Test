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

                    return table.Columns.Select(column =>
                    {
                        var (encryptionType, cekName) = ResolveEncryptionMetadata(column);
                        return new AeColumnTarget
                        {
                            Schema = schema,
                            Table = tableName,
                            Column = column.Name,
                            EncryptionType = encryptionType,
                            CekName = cekName
                        };
                    });
                })
                .OrderBy(r => r.Schema, StringComparer.OrdinalIgnoreCase)
                .ThenBy(r => r.Table, StringComparer.OrdinalIgnoreCase)
                .ThenBy(r => r.Column, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }

        private static (string EncryptionType, string? CekName) ResolveEncryptionMetadata(IColumn column)
        {
            var propertyWithAe = column.PropertyMappings
                .Select(pm => pm.Property)
                .Select(p => new
                {
                    Property = p,
                    TypeAnnotation = p.FindAnnotation(AeAnnotationNames.Type)?.Value as string
                })
                .FirstOrDefault(x => !string.IsNullOrWhiteSpace(x.TypeAnnotation));

            if (propertyWithAe == null)
            {
                return (nameof(AeEncryptionType.PlainText), null);
            }

            var cekAnnotation = propertyWithAe.Property.FindAnnotation(AeAnnotationNames.CEK);
            var cekName = cekAnnotation?.Value as string;
            
            return (propertyWithAe.TypeAnnotation, string.IsNullOrWhiteSpace(cekName) ? null : cekName)!;
        }
    }
}