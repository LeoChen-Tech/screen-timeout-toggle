using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace ScreenTimeoutToast;

internal sealed record ToastPipeRequest(
    string Title,
    string Line1,
    string Line2,
    int Seconds,
    bool IsError,
    string? DiagnosticsPath);

internal sealed class ToastPipeServer : IDisposable
{
    public const string PipeName = "ScreenTimeoutToastHost";

    private readonly Action<ToastOptions> _showToast;
    private readonly CancellationTokenSource _cancellation = new();

    public ToastPipeServer(Action<ToastOptions> showToast)
    {
        _showToast = showToast;
    }

    public async Task RunAsync()
    {
        while (!_cancellation.IsCancellationRequested)
        {
            try
            {
                await AcceptOneAsync(_cancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (_cancellation.IsCancellationRequested)
            {
                return;
            }
            catch
            {
                await Task.Delay(100, _cancellation.Token).ConfigureAwait(false);
            }
        }
    }

    private async Task AcceptOneAsync(CancellationToken cancellationToken)
    {
        await using var pipe = new NamedPipeServerStream(
            PipeName,
            PipeDirection.InOut,
            1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);

        using var reader = new StreamReader(pipe, new UTF8Encoding(false), leaveOpen: true);
        await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true)
        {
            AutoFlush = true
        };

        using var requestTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        requestTimeout.CancelAfter(TimeSpan.FromSeconds(2));
        var json = await reader.ReadLineAsync(requestTimeout.Token).ConfigureAwait(false);
        var request = string.IsNullOrWhiteSpace(json)
            ? null
            : JsonSerializer.Deserialize<ToastPipeRequest>(json);
        if (request is null)
        {
            await writer.WriteLineAsync("ERROR").ConfigureAwait(false);
            return;
        }

        _showToast(ToastOptions.FromPipeRequest(request));
        await writer.WriteLineAsync("OK").ConfigureAwait(false);
    }

    public void Dispose()
    {
        _cancellation.Cancel();
        _cancellation.Dispose();
    }
}
