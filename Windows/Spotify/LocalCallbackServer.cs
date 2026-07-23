using System.Net;

namespace MuseSaverWin.Spotify;

/// <summary>
/// A tiny single-shot HTTP server that listens on 127.0.0.1 to catch the OAuth
/// redirect and extract the "code" query parameter.
/// </summary>
internal sealed class LocalCallbackServer
{
    private readonly int _port;
    private HttpListener? _listener;

    public event Action<string>? CodeReceived;
    public event Action<string>? ErrorReceived;

    public LocalCallbackServer(int port)
    {
        _port = port;
    }

    public void Start()
    {
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{_port}/callback/");
        listener.Start();
        _listener = listener;
        _ = Task.Run(AcceptLoop);
    }

    public void Stop()
    {
        try { _listener?.Stop(); } catch { /* already stopped */ }
        _listener = null;
    }

    private async Task AcceptLoop()
    {
        try
        {
            while (_listener is { IsListening: true })
            {
                var context = await _listener.GetContextAsync();
                Handle(context);
                break; // single-shot: one callback is all we expect
            }
        }
        catch (HttpListenerException)
        {
            // Listener was stopped — expected on shutdown.
        }
        catch (ObjectDisposedException)
        {
            // Listener was disposed — expected on shutdown.
        }
    }

    private void Handle(HttpListenerContext context)
    {
        var query = context.Request.QueryString;
        var code = query["code"];
        var error = query["error"];

        string title = code != null ? "MuseSaver connected" : "Authorization failed";
        string message = code != null
            ? "You can close this tab and return to the app."
            : (error ?? "Unknown error.");
        var body = HtmlPage(title, message);

        var buffer = System.Text.Encoding.UTF8.GetBytes(body);
        context.Response.ContentType = "text/html; charset=utf-8";
        context.Response.ContentLength64 = buffer.Length;
        context.Response.OutputStream.Write(buffer, 0, buffer.Length);
        context.Response.OutputStream.Close();

        if (code != null)
        {
            CodeReceived?.Invoke(code);
        }
        else
        {
            ErrorReceived?.Invoke(error ?? "unknown_error");
        }
        Stop();
    }

    private static string HtmlPage(string title, string message) => $"""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>{title}</title></head>
        <body style="font-family:Segoe UI,system-ui,sans-serif;background:#0b0b0f;color:#f5f5f7;text-align:center;padding-top:120px">
        <h1 style="font-weight:600">{title}</h1>
        <p style="opacity:0.7">{message}</p>
        </body></html>
        """;
}
