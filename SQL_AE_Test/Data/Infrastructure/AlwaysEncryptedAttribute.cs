using System;

namespace SQL_AE_Test.Data.Infrastructure
{
    [AttributeUsage(AttributeTargets.Property)]
    public sealed class AlwaysEncryptedAttribute : Attribute
    {
        public AlwaysEncryptedAttribute(AeEncryptionType type, string cekName = "CEK_App")
            => (Type, ColumnEncryptionKeyName) = (type, cekName);

        public AeEncryptionType Type { get; }
        public string ColumnEncryptionKeyName { get; }
    }
}