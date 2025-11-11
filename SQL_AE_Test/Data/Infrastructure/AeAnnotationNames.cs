namespace SQL_AE_Test.Data.Infrastructure
{
    public static class AeAnnotationNames
    {
        public const string Prefix = "AE:";
        public const string Type   = Prefix + "Type";   // "Deterministic" | "Randomized | "PlainText"
        public const string CEK    = Prefix + "CekName"; // e.g., "CEK_PII"
    }
}