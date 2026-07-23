using System.Text.Json.Serialization;

namespace MuseSaverWin.Spotify;

internal sealed class TokenResponse
{
    [JsonPropertyName("access_token")]
    public string AccessToken { get; set; } = "";

    [JsonPropertyName("token_type")]
    public string? TokenType { get; set; }

    [JsonPropertyName("expires_in")]
    public int ExpiresIn { get; set; }

    [JsonPropertyName("refresh_token")]
    public string? RefreshToken { get; set; }

    [JsonPropertyName("scope")]
    public string? Scope { get; set; }
}

internal sealed class CurrentlyPlaying
{
    [JsonPropertyName("progress_ms")]
    public int? ProgressMs { get; set; }

    [JsonPropertyName("is_playing")]
    public bool IsPlaying { get; set; }

    [JsonPropertyName("item")]
    public Track? Item { get; set; }

    [JsonPropertyName("shuffle_state")]
    public bool? ShuffleState { get; set; }

    [JsonPropertyName("repeat_state")]
    public string? RepeatState { get; set; }
}

internal sealed class Track : IEquatable<Track>
{
    [JsonPropertyName("id")]
    public string? Id { get; set; }

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("duration_ms")]
    public int DurationMs { get; set; }

    [JsonPropertyName("artists")]
    public List<Artist> Artists { get; set; } = new();

    [JsonPropertyName("album")]
    public Album Album { get; set; } = new();

    [JsonIgnore]
    public string ArtistNames => string.Join(", ", Artists.Select(a => a.Name));

    [JsonIgnore]
    public string Key => Id ?? $"{Name}::{ArtistNames}";

    [JsonIgnore]
    public string? AlbumArtUrl => Album.Images.FirstOrDefault()?.Url;

    public bool Equals(Track? other) => other != null && Key == other.Key;
    public override bool Equals(object? obj) => Equals(obj as Track);
    public override int GetHashCode() => Key.GetHashCode();
}

internal sealed class Artist
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";
}

internal sealed class Album
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("images")]
    public List<SpotifyImage> Images { get; set; } = new();
}

internal sealed class SpotifyImage
{
    [JsonPropertyName("url")]
    public string Url { get; set; } = "";

    [JsonPropertyName("width")]
    public int? Width { get; set; }

    [JsonPropertyName("height")]
    public int? Height { get; set; }
}

internal sealed class QueueResponse
{
    [JsonPropertyName("queue")]
    public List<Track> Queue { get; set; } = new();
}
