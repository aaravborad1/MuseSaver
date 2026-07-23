using System.Diagnostics;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using MuseSaverWin.Support;

namespace MuseSaverWin.Spotify;

internal enum AuthError
{
    NotConnected,
    TokenMissing,
    BadResponse
}

internal sealed class AuthException(AuthError error) : Exception(error.ToString())
{
    public AuthError Error { get; } = error;
}

/// <summary>
/// Handles the OAuth 2.0 Authorization Code + PKCE flow, token storage, and refresh.
/// The refresh token is persisted in Windows Credential Manager; the access token
/// lives only in memory and is refreshed on demand shortly before it expires.
/// </summary>
internal sealed class SpotifyAuth
{
    private const string RefreshTokenAccount = "refresh-token";
    private static readonly HttpClient Http = new();

    private string? _accessToken;
    private DateTime _accessTokenExpiry;
    private string? _codeVerifier;
    private LocalCallbackServer? _server;
    private Task<string>? _refreshTask;

    public bool IsConnected { get; private set; }

    public event Action? ConnectionChanged;

    public SpotifyAuth()
    {
        IsConnected = CredentialStore.Get(RefreshTokenAccount) != null;
    }

    private void SetConnected(bool connected)
    {
        if (IsConnected == connected) return;
        IsConnected = connected;
        ConnectionChanged?.Invoke();
    }

    // MARK: - Authorization

    /// <summary>Starts the local callback server and opens the Spotify consent page.</summary>
    public void Connect()
    {
        var verifier = RandomCodeVerifier();
        _codeVerifier = verifier;
        var challenge = CodeChallenge(verifier);

        var server = new LocalCallbackServer(SpotifyConfig.CallbackPort);
        server.CodeReceived += code => _ = ExchangeCodeAsync(code);
        server.ErrorReceived += error => Debug.WriteLine($"MuseSaver: authorization error — {error}");
        try
        {
            server.Start();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"MuseSaver: failed to start callback server — {ex.Message}");
            return;
        }
        _server = server;

        var query = FormEncoding.Encode(new Dictionary<string, string>
        {
            ["client_id"] = SpotifyConfig.ClientId,
            ["response_type"] = "code",
            ["redirect_uri"] = SpotifyConfig.RedirectUri,
            ["code_challenge_method"] = "S256",
            ["code_challenge"] = challenge,
            ["scope"] = SpotifyConfig.Scopes
        });
        var url = $"https://accounts.spotify.com/authorize?{query}";
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }

    public void Disconnect()
    {
        _accessToken = null;
        _accessTokenExpiry = default;
        SetConnected(false);
        CredentialStore.Delete(RefreshTokenAccount);
    }

    private async Task ExchangeCodeAsync(string code)
    {
        if (_codeVerifier is not { } verifier) return;
        var body = FormEncoding.Encode(new Dictionary<string, string>
        {
            ["grant_type"] = "authorization_code",
            ["code"] = code,
            ["redirect_uri"] = SpotifyConfig.RedirectUri,
            ["client_id"] = SpotifyConfig.ClientId,
            ["code_verifier"] = verifier
        });
        try
        {
            var token = await PostTokenAsync(body);
            Apply(token);
            _server?.Stop();
            _server = null;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"MuseSaver: token exchange failed — {ex.Message}");
        }
    }

    // MARK: - Access token

    /// <summary>Returns a valid access token, refreshing it first if necessary.</summary>
    public async Task<string> ValidAccessTokenAsync()
    {
        if (_accessToken != null && _accessTokenExpiry > DateTime.UtcNow)
            return _accessToken;

        // Coalesce concurrent refreshes into a single in-flight request.
        if (_refreshTask is { } existing)
            return await existing;

        var task = PerformRefreshAsync();
        _refreshTask = task;
        try
        {
            return await task;
        }
        finally
        {
            _refreshTask = null;
        }
    }

    private async Task<string> PerformRefreshAsync()
    {
        var refreshToken = CredentialStore.Get(RefreshTokenAccount)
            ?? throw new AuthException(AuthError.NotConnected);
        var body = FormEncoding.Encode(new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
            ["client_id"] = SpotifyConfig.ClientId
        });
        var token = await PostTokenAsync(body);
        Apply(token);
        return _accessToken ?? throw new AuthException(AuthError.TokenMissing);
    }

    private async Task<TokenResponse> PostTokenAsync(string body)
    {
        using var content = new StringContent(body, Encoding.UTF8, "application/x-www-form-urlencoded");
        using var response = await Http.PostAsync("https://accounts.spotify.com/api/token", content);

        if ((int)response.StatusCode == 400)
        {
            // Refresh token has been revoked — force the user to reconnect.
            CredentialStore.Delete(RefreshTokenAccount);
            SetConnected(false);
            throw new AuthException(AuthError.NotConnected);
        }
        if (!response.IsSuccessStatusCode)
            throw new AuthException(AuthError.BadResponse);

        var json = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<TokenResponse>(json)
            ?? throw new AuthException(AuthError.BadResponse);
    }

    private void Apply(TokenResponse token)
    {
        _accessToken = token.AccessToken;
        // Refresh a minute early to avoid using a token that expires mid-request.
        _accessTokenExpiry = DateTime.UtcNow.AddSeconds(token.ExpiresIn - 60);
        if (!string.IsNullOrEmpty(token.RefreshToken))
        {
            CredentialStore.Set(token.RefreshToken, RefreshTokenAccount);
        }
        SetConnected(true);
    }

    // MARK: - PKCE helpers

    private static string RandomCodeVerifier()
    {
        const string allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
        var bytes = RandomNumberGenerator.GetBytes(64);
        var chars = bytes.Select(b => allowed[b % allowed.Length]).ToArray();
        return new string(chars);
    }

    private static string CodeChallenge(string verifier)
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(verifier));
        return Base64UrlEncoder.Encode(digest);
    }
}
