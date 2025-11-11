using System;

namespace SQL_AE_Test.Data.Infrastructure
{
    public sealed class AeColumnTarget
    {
        public string Schema { get; init; } = string.Empty;
        public string Table { get; init; } = string.Empty;
        public string Column { get; init; } = string.Empty;
        public string EncryptionType { get; init; } = string.Empty;
        public string? CekName { get; init; }

        public override string ToString()
            => $"{Schema}.{Table}.{Column} ({EncryptionType}{(string.IsNullOrEmpty(CekName) ? string.Empty : $", CEK: {CekName}")})";
    }
}
