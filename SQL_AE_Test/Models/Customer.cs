using SQL_AE_Test.Data.Infrastructure;

namespace SQL_AE_Test.Models
{
    public class Customer
    {
        public required int Id { get; set; }

        [AlwaysEncrypted(AeEncryptionType.Deterministic, cekName: "CEK_PII")]
        public required string SSN { get; set; }

        [AlwaysEncrypted(AeEncryptionType.Randomized, cekName: "CEK_PII")]
        public DateTime? BirthDate { get; set; }

        public string? Description { get; set; }
    }
}