using System.Globalization;
using System.Text;

namespace ScreenTimeoutToast;

internal sealed record ToastOptions(
    string Title,
    string Line1,
    string Line2,
    int Seconds,
    bool IsError,
    string? DiagnosticsPath)
{
    public static ToastOptions Default { get; } = new(
        "关屏时间已切换",
        "已接通电源 · 已静音",
        "屏幕关闭：10 秒",
        3,
        false,
        null);

    public static ToastOptions Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var switches = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        for (var index = 1; index < args.Length; index++)
        {
            var argument = args[index];
            if (!argument.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            if (index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal))
            {
                values[argument] = args[++index];
            }
            else
            {
                switches.Add(argument);
            }
        }

        var title = DecodeRequired(values, "--title-b64");
        var line1 = DecodeRequired(values, "--line1-b64");
        var line2 = DecodeRequired(values, "--line2-b64");

        var seconds = 3;
        if (values.TryGetValue("--seconds", out var secondsText) &&
            (!int.TryParse(secondsText, NumberStyles.None, CultureInfo.InvariantCulture, out seconds) ||
             seconds is < 1 or > 15))
        {
            throw new ArgumentOutOfRangeException(nameof(args), "--seconds must be between 1 and 15.");
        }

        values.TryGetValue("--diagnostics", out var diagnosticsPath);
        return new ToastOptions(title, line1, line2, seconds, switches.Contains("--error"), diagnosticsPath);
    }

    public static ToastOptions FromPipeRequest(ToastPipeRequest request) => new(
        request.Title,
        request.Line1,
        request.Line2,
        Math.Clamp(request.Seconds, 1, 15),
        request.IsError,
        request.DiagnosticsPath);

    private static string DecodeRequired(IReadOnlyDictionary<string, string> values, string key)
    {
        if (!values.TryGetValue(key, out var encoded))
        {
            throw new ArgumentException($"Missing required argument {key}.");
        }

        return Encoding.UTF8.GetString(Convert.FromBase64String(encoded));
    }
}
