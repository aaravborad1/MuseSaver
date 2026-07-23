namespace MuseSaverWin.Spotify;

/// <summary>
/// Static configuration for the Spotify integration. The client ID is read from the
/// SPOTIFY_CLIENT_ID environment variable if set, otherwise falls back to the
/// constant below. Register your own app at https://developer.spotify.com/dashboard.
/// No client secret is required — MuseSaver uses Authorization Code + PKCE.
/// </summary>
internal static class SpotifyConfig
{
    public static string ClientId
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("SPOTIFY_CLIENT_ID");
            return string.IsNullOrEmpty(env) ? "42f10bf595ee4c7db07f7be487b5009f" : env;
        }
    }

    public const string RedirectUri = "http://127.0.0.1:8888/callback";
    public const int CallbackPort = 8888;
    public const string Scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state";
}
