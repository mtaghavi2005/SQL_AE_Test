using Microsoft.EntityFrameworkCore.Design;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Migrations.Design;
using Microsoft.Extensions.DependencyInjection;

namespace SQL_AE_Test.Data.Infrastructure;

public class DesignTimeEfCoreServices:  IDesignTimeServices
{
    public void ConfigureDesignTimeServices(IServiceCollection services)
    {
        // replace the default MigrationsScaffolder with our custom one
        services.AddSingleton<IMigrationsScaffolder>(sp =>
            new AeMigrationsScaffolder(
                inner: ActivatorUtilities.CreateInstance<MigrationsScaffolder>(sp),
                differ: sp.GetRequiredService<IMigrationsModelDiffer>(),
                migrationsAssembly: sp.GetRequiredService<IMigrationsAssembly>(),
                current: sp.GetRequiredService<ICurrentDbContext>()));
    }
}