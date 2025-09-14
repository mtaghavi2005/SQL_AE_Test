using System.Reflection;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using Microsoft.EntityFrameworkCore.Metadata.Conventions;
using Microsoft.EntityFrameworkCore.Metadata.Conventions.Infrastructure;
using SQL_AE_Test.Data.Infrastructure;

public sealed class AlwaysEncryptedAttributeConvention 
    : PropertyAttributeConventionBase<AlwaysEncryptedAttribute>
{
    public AlwaysEncryptedAttributeConvention(ProviderConventionSetBuilderDependencies dependencies)
        : base(dependencies) { }

    protected override void ProcessPropertyAdded(
        IConventionPropertyBuilder propertyBuilder,
        AlwaysEncryptedAttribute attribute,
        MemberInfo clrMember,
        IConventionContext context)
    {
        propertyBuilder.HasAnnotation(AeAnnotationNames.Type, attribute.Type.ToString());
        propertyBuilder.HasAnnotation(AeAnnotationNames.CEK, attribute.ColumnEncryptionKeyName);
    }
}