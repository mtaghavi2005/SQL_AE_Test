namespace SQL_AE_Test.Data.Infrastructure;

public sealed class AeTargetKeyComparer : IEqualityComparer<(string Schema, string Table, string Column)>
{
    public bool Equals((string Schema, string Table, string Column) x,
        (string Schema, string Table, string Column) y) =>
        string.Equals(x.Schema, y.Schema, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(x.Table,  y.Table,  StringComparison.OrdinalIgnoreCase) &&
        string.Equals(x.Column, y.Column, StringComparison.OrdinalIgnoreCase);

    public int GetHashCode((string Schema, string Table, string Column) obj)
    {
        unchecked
        {
            var h1 = StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Schema ?? string.Empty);
            var h2 = StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Table  ?? string.Empty);
            var h3 = StringComparer.OrdinalIgnoreCase.GetHashCode(obj.Column ?? string.Empty);
            return ((h1 * 397) ^ h2) * 397 ^ h3;
        }
    }
}