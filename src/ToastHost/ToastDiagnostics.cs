using System.Diagnostics;
using System.Text.Json;

namespace ScreenTimeoutToast;

internal static class ToastDiagnostics
{
    public static readonly Stopwatch Lifetime = Stopwatch.StartNew();

    public static void WriteSuccess(string? path, object payload)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(path, JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true }));
    }

    public static void WriteFailure(string[] args, Exception exception)
    {
        var diagnosticsIndex = Array.FindIndex(args, value =>
            string.Equals(value, "--diagnostics", StringComparison.OrdinalIgnoreCase));
        if (diagnosticsIndex < 0 || diagnosticsIndex + 1 >= args.Length)
        {
            return;
        }

        WriteSuccess(args[diagnosticsIndex + 1], new
        {
            Success = false,
            Exception = exception.ToString(),
            ElapsedMilliseconds = Lifetime.Elapsed.TotalMilliseconds
        });
    }
}
