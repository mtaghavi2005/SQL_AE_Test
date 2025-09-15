
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Configuration;
using SQL_AE_Test.Data;

var builder = new ConfigurationBuilder()
	.SetBasePath(Directory.GetCurrentDirectory())
	.AddJsonFile("appsettings.json", optional: true, reloadOnChange: true)
	.AddUserSecrets(System.Reflection.Assembly.GetExecutingAssembly(), optional: true)
	.AddEnvironmentVariables();

var configuration = builder.Build();

var services = new ServiceCollection();
services.AddDbContext<AppDbContext>(options =>
	options.UseSqlServer(configuration.GetConnectionString("DefaultConnection")));
var provider = services.BuildServiceProvider();

using var scope = provider.CreateScope();
var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
Console.WriteLine($"DbContext ready. Customer count: {db.Customers.Count()}");
