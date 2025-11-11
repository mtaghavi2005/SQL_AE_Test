using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace SQL_AE_Test.Data.Infrastructure
{
    public static class AeTargetExtensions
    {
        /// <summary>
        /// Dumps Always Encrypted column targets from the DbContext model as JSON.
        /// </summary>
        /// <param name="context">The DbContext instance.</param>
        /// <param name="indent">Whether to format the JSON with indentation. Default is true.</param>
        /// <returns>JSON string representing the AE column targets.</returns>
        public static string DumpAeTargetsAsJson(this DbContext context, bool indent = true)
        {
            ArgumentNullException.ThrowIfNull(context);

            var targets = AeColumnTargetDiscovery.FromModel(context.Model);
            var json = JsonSerializer.Serialize(targets, new JsonSerializerOptions
            {
                WriteIndented = indent,
                PropertyNamingPolicy = null
            });

            return json;
        }

        /// <summary>
        /// Extension method to run Always Encrypted commands on <see cref="IHost"/> with the provided
        /// arguments. The method either executes the AE command or runs the host normally.
        /// </summary>
        /// <example>
        /// dotnet run -- ae-dump-targets
        /// dotnet run -- ae-dump-targets --output output.json
        /// </example>
        /// <typeparam name="TContext">The DbContext type.</typeparam>
        /// <param name="host">The IHost instance.</param>
        /// <param name="args">Command line arguments to be passed to the host.</param>
        public static async Task RunWithAlwaysEncryptedCommandsAsync<TContext>(this IHost host, string[] args) 
            where TContext : DbContext
        {
            if (args.IsAlwaysEncryptedCommand())
            {
                await using var scope = host.Services.CreateAsyncScope();
                var dbContext = scope.ServiceProvider.GetRequiredService<TContext>();
                var json = dbContext.DumpAeTargetsAsJson();
                
                // Check if --output parameter is provided
                var outputIndex = Array.IndexOf(args, "--output");
                if (outputIndex >= 0 && outputIndex + 1 < args.Length)
                {
                    var filePath = args[outputIndex + 1];
                    await File.WriteAllTextAsync(filePath, json);
                    Console.WriteLine($"AE targets saved to: {filePath}");
                }
                else
                {
                    Console.WriteLine(json);
                }
                
                return;
            }

            await host.RunAsync();
        }

        /// <summary>
        /// Checks if the provided arguments are an Always Encrypted command.
        /// </summary>
        /// <param name="args">The command line arguments.</param>
        /// <returns>
        /// Returns <see langword="true"/> if the arguments are an AE command; otherwise, <see langword="false"/>.
        /// </returns>
        public static bool IsAlwaysEncryptedCommand(this string[] args)
            => args is ["ae-dump-targets", ..];
    }
}
