using System;
using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using SQL_AE_Test.Data;
using SQL_AE_Test.Data.Infrastructure;

var builder = new ConfigurationBuilder()
    .SetBasePath(Directory.GetCurrentDirectory())
    .AddJsonFile("appsettings.json", optional: true, reloadOnChange: true)
    .AddUserSecrets(System.Reflection.Assembly.GetExecutingAssembly(), optional: true)
    .AddEnvironmentVariables();

var configuration = builder.Build();

var services = new ServiceCollection();
services.AddDbContext<AppDbContext>(options =>
    options.UseSqlServer(configuration.GetConnectionString("DefaultConnection")));

await using var provider = services.BuildServiceProvider();
await using var scope = provider.CreateAsyncScope();
var dbContext = scope.ServiceProvider.GetRequiredService<AppDbContext>();

if (args.Length > 0 && string.Equals(args[0], "ae-dump-targets", StringComparison.OrdinalIgnoreCase))
{
    var targets = AeColumnTargetDiscovery.FromModel(dbContext.Model);
    var json = JsonSerializer.Serialize(targets, new JsonSerializerOptions
    {
        WriteIndented = true,
        PropertyNamingPolicy = null
    });

    Console.WriteLine(json);
    return;
}

Console.WriteLine($"DbContext ready. Customer count: {await dbContext.Customers.CountAsync()}");
