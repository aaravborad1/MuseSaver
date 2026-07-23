using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using MuseSaverWin.Spotify;

namespace MuseSaverWin.Lyrics;

internal sealed record LyricLine(double Time, string Text);

internal sealed class LrcLibResult
{
    [JsonPropertyName("syncedLyrics")]
    public string? SyncedLyrics { get; set; }

    [JsonPropertyName("plainLyrics")]
    public string? PlainLyrics { get; set; }

    [JsonPropertyName("duration")]
    public double? Duration { get; set; }
}

/// <summary>Fetches time-synced lyrics from lrclib.net and caches them per track.</summary>
internal sealed class LyricsService
{
    private const string UserAgent = "MuseSaver/1.0 (https://github.com/aaravborad1/MuseSaver)";
    private static readonly HttpClient Http = new();

    private readonly Dictionary<string, List<LyricLine>> _memoryCache = new();
    private readonly SemaphoreSlim _gate = new(1, 1);

    private static readonly string CacheDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MuseSaver", "lyrics");

    static LyricsService()
    {
        Directory.CreateDirectory(CacheDir);
    }

    /// <summary>Returns synced lyric lines for a track, or an empty list when none are found.</summary>
    public async Task<List<LyricLine>> LyricsForAsync(Track track)
    {
        var key = track.Key;

        await _gate.WaitAsync();
        try
        {
            if (_memoryCache.TryGetValue(key, out var cached)) return cached;
        }
        finally { _gate.Release(); }

        var disk = ReadDiskCache(key);
        if (disk != null)
        {
            await _gate.WaitAsync();
            try { _memoryCache[key] = disk; } finally { _gate.Release(); }
            return disk;
        }

        List<LyricLine> lines;
        try { lines = await FetchAsync(track); }
        catch { lines = new List<LyricLine>(); }

        await _gate.WaitAsync();
        try { _memoryCache[key] = lines; } finally { _gate.Release(); }

        if (lines.Count > 0) WriteDiskCache(key, lines);
        return lines;
    }

    // MARK: - Fetching

    private async Task<List<LyricLine>> FetchAsync(Track track)
    {
        // Race the exact-match /get and the fuzzier /search in parallel; the first
        // non-empty result wins.
        var exactTask = TryAsync(() => FetchExactAsync(track));
        var searchTask = TryAsync(() => FetchSearchAsync(track));

        var pending = new List<Task<List<LyricLine>?>> { exactTask, searchTask };
        while (pending.Count > 0)
        {
            var finished = await Task.WhenAny(pending);
            pending.Remove(finished);
            var result = await finished;
            if (result is { Count: > 0 }) return result;
        }
        return new List<LyricLine>();
    }

    private static async Task<T?> TryAsync<T>(Func<Task<T?>> action) where T : class
    {
        try { return await action(); }
        catch { return null; }
    }

    private async Task<List<LyricLine>?> FetchExactAsync(Track track)
    {
        var artist = Uri.EscapeDataString(track.Artists.FirstOrDefault()?.Name ?? track.ArtistNames);
        var name = Uri.EscapeDataString(track.Name);
        var album = Uri.EscapeDataString(track.Album.Name);
        var duration = track.DurationMs / 1000;
        var url = $"https://lrclib.net/api/get?artist_name={artist}&track_name={name}&album_name={album}&duration={duration}";

        var result = await RequestAsync(url);
        return result != null ? Synced(result) : null;
    }

    private async Task<List<LyricLine>?> FetchSearchAsync(Track track)
    {
        var name = Uri.EscapeDataString(track.Name);
        var artist = Uri.EscapeDataString(track.Artists.FirstOrDefault()?.Name ?? track.ArtistNames);
        var url = $"https://lrclib.net/api/search?track_name={name}&artist_name={artist}";

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd(UserAgent);
        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;

        var json = await response.Content.ReadAsStringAsync();
        var results = JsonSerializer.Deserialize<List<LrcLibResult>>(json) ?? new();
        foreach (var result in results)
        {
            var lines = Synced(result);
            if (lines is { Count: > 0 }) return lines;
        }
        return null;
    }

    private async Task<LrcLibResult?> RequestAsync(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.UserAgent.ParseAdd(UserAgent);
        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;
        var json = await response.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<LrcLibResult>(json);
    }

    private static List<LyricLine>? Synced(LrcLibResult result)
    {
        if (string.IsNullOrEmpty(result.SyncedLyrics)) return null;
        return ParseLrc(result.SyncedLyrics);
    }

    // MARK: - Disk cache

    private static string CacheFile(string key)
    {
        var safe = Base64UrlEncode(System.Text.Encoding.UTF8.GetBytes(key));
        return Path.Combine(CacheDir, safe + ".json");
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    private static List<LyricLine>? ReadDiskCache(string key)
    {
        try
        {
            var file = CacheFile(key);
            if (!File.Exists(file)) return null;
            var json = File.ReadAllText(file);
            return JsonSerializer.Deserialize<List<LyricLine>>(json);
        }
        catch { return null; }
    }

    private static void WriteDiskCache(string key, List<LyricLine> lines)
    {
        try
        {
            File.WriteAllText(CacheFile(key), JsonSerializer.Serialize(lines));
        }
        catch { /* best-effort */ }
    }

    // MARK: - LRC parsing

    private static readonly Regex TimestampPattern = new(@"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]", RegexOptions.Compiled);

    /// <summary>
    /// Parses LRC-format text into sorted, timestamped lines. A single line can carry
    /// multiple timestamps (e.g. a repeated chorus), which are expanded.
    /// </summary>
    public static List<LyricLine> ParseLrc(string raw)
    {
        var lines = new List<LyricLine>();
        foreach (var rawLine in raw.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var matches = TimestampPattern.Matches(rawLine);
            if (matches.Count == 0) continue;
            var last = matches[^1];

            var textStart = last.Index + last.Length;
            var text = rawLine[textStart..].Trim();

            foreach (Match match in matches)
            {
                var minutes = double.Parse(match.Groups[1].Value);
                var seconds = double.Parse(match.Groups[2].Value);
                var fraction = 0.0;
                if (match.Groups[3].Success)
                {
                    var fractionString = match.Groups[3].Value;
                    fraction = double.Parse(fractionString) / Math.Pow(10, fractionString.Length);
                }
                var time = minutes * 60 + seconds + fraction;
                lines.Add(new LyricLine(time, text));
            }
        }
        return lines.OrderBy(l => l.Time).ToList();
    }
}
