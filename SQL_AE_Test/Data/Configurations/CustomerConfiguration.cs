using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata.Builders;
using SQL_AE_Test.Models;

namespace SQL_AE_Test.Data.Configurations
{
    public class CustomerConfiguration : IEntityTypeConfiguration<Customer>
    {
        public void Configure(EntityTypeBuilder<Customer> builder)
        {
            builder.HasKey(e => e.Id);

            builder.Property(e => e.SSN);
            
            builder.Property(e => e.BirthDate)
                .IsRequired();
            
            builder.Property(e => e.Description)
                .HasMaxLength(500);

            builder.Property(e => e.SSN);

            builder.Property(e => e.BirthDate);
        }
    }
}