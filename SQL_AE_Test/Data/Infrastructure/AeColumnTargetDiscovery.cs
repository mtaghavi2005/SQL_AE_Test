using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;

namespace SQL_AE_Test.Data.Infrastructure
{
    public static class AeColumnTargetDiscovery
    {
        public static IReadOnlyList<AeColumnTarget> FromModel(IModel model)
        {
            if (model is null)
            {
                throw new ArgumentNullException(nameof(model));
            }

            var relationalModel = model.GetRelationalModel();
            var results = new List<AeColumnTarget>();

            foreach (var table in relationalModel.Tables)
            {
                var schema = table.Schema ?? "dbo";
                var tableName = table.Name;

                foreach (var column in table.Columns)
                {
                    var (encryptionType, cekName) = ResolveEncryptionMetadata(column);

                    results.Add(new AeColumnTarget
                    {
                        Schema = schema,
                        Table = tableName,
                        Column = column.Name,
                        EncryptionType = encryptionType,
                        CekName = cekName
                    });
                }
            }

            return results
                .OrderBy(r => r.Schema, StringComparer.OrdinalIgnoreCase)
                .ThenBy(r => r.Table, StringComparer.OrdinalIgnoreCase)
                .ThenBy(r => r.Column, StringComparer.OrdinalIgnoreCase)
                .ToArray();
        }

        private static (string EncryptionType, string? CekName) ResolveEncryptionMetadata(IColumn column)
        {
            foreach (var propertyMapping in column.PropertyMappings)
            {
                var property = propertyMapping.Property;
                var typeAnnotation = property.FindAnnotation(AeAnnotationNames.Type);
                if (typeAnnotation?.Value is string annotationValue && !string.IsNullOrWhiteSpace(annotationValue))
                {
                    var cekAnnotation = property.FindAnnotation(AeAnnotationNames.CEK);
                    var cekName = cekAnnotation?.Value as string;
                    return (annotationValue, string.IsNullOrWhiteSpace(cekName) ? null : cekName);
                }
            }

            return ("Plain", null);
        }
    }
}
