using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace MuseSaverWin.Spotify;

internal enum ApiError { Unauthorized, Http, BadResponse }

internal sealed class ApiException(ApiError error, int? statusCode = null) : Exception(error.ToString())
{
    public ApiError Error { get; } = error;
    public int? StatusCode { get; } = statusCode;
}

/// <summary>Thin client for the Spotify Web API endpoints MuseSaver needs.</summary>
internal sealed class SpotifyApi
{
    private static readonly HttpClient Http = new();
    private readonly SpotifyAuth _auth;

    public SpotifyApi(SpotifyAuth auth)
    {
        _auth = auth;
    }

    /// <summary>
    /// Fetches the full player state. Returns null when there is no active playback
    /// (Spotify replies with HTTP 204).
    /// </summary>
    public async Task<CurrentlyPlaying?> CurrentlyPlayingAsync()
    {
        var token = await _auth.ValidAccessTokenAsync();
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.spotify.com/v1/me/player");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        using var response = await Http.SendAsync(request);
        switch ((int)response.StatusCode)
        {
            case 204:
                return null;
            case 200:
                var json = await response.Content.ReadAsStringAsync();
                if (string.IsNullOrEmpty(json)) return null;
                return JsonSerializer.Deserialize<CurrentlyPlaying>(json);
            case 401:
                throw new ApiException(ApiError.Unauthorized);
            default:
                throw new ApiException(ApiError.Http, (int)response.StatusCode);
        }
    }

    /// <summary>Returns the upcoming tracks in the user's play queue.</summary>
    public async Task<List<Track>> UpcomingQueueAsync()
    {
        try
        {
            var token = await _auth.ValidAccessTokenAsync();
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.spotify.com/v1/me/player/queue");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

            using var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return new List<Track>();

            var json = await response.Content.ReadAsStringAsync();
            var parsed = JsonSerializer.Deserialize<QueueResponse>(json);
            return parsed?.Queue ?? new List<Track>();
        }
        catch
        {
            return new List<Track>();
        }
    }

    // MARK: - Playback commands (require user-modify-playback-state)

    public Task PlayAsync() => CommandAsync(HttpMethod.Put, "play");
    public Task PauseAsync() => CommandAsync(HttpMethod.Put, "pause");
    public Task NextTrackAsync() => CommandAsync(HttpMethod.Post, "next");
    public Task PreviousTrackAsync() => CommandAsync(HttpMethod.Post, "previous");

    public Task SeekAsync(int positionMs) =>
        CommandAsync(HttpMethod.Put, "seek", $"position_ms={positionMs}");

    public Task SetShuffleAsync(bool on) =>
        CommandAsync(HttpMethod.Put, "shuffle", $"state={(on ? "true" : "false")}");

    /// <summary>mode is one of "off", "context" (playlist/album), or "track".</summary>
    public Task SetRepeatAsync(string mode) =>
        CommandAsync(HttpMethod.Put, "repeat", $"state={mode}");

    private async Task CommandAsync(HttpMethod method, string path, string? query = null)
    {
        var token = await _auth.ValidAccessTokenAsync();
        var url = $"https://api.spotify.com/v1/me/player/{path}";
        if (query != null) url += $"?{query}";

        using var request = new HttpRequestMessage(method, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            // 404 = no active device; 403 = missing scope or restricted (e.g. free tier).
            if ((int)response.StatusCode == 401) throw new ApiException(ApiError.Unauthorized);
            throw new ApiException(ApiError.Http, (int)response.StatusCode);
        }
    }
}
