using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using MuseSaverWin.Lyrics;
using MuseSaverWin.Spotify;
using Color = System.Windows.Media.Color;

namespace MuseSaverWin.LockScreen;

/// <summary>
/// Central observable store for the lock screen. Polls Spotify while the window is
/// open, loads lyrics and artwork on track changes, and estimates playback position
/// between polls so lyric highlighting stays smooth.
/// </summary>
internal sealed class NowPlayingModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (Equals(field, value)) return;
        field = value;
        RaisePropertyChanged(name);
    }

    /// <summary>
    /// Polling runs on background threads, but WPF bindings must observe
    /// PropertyChanged on the UI thread, so always marshal through the dispatcher.
    /// </summary>
    private void RaisePropertyChanged(string? name)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
        else
        {
            dispatcher.BeginInvoke(() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name)));
        }
    }

    private readonly SpotifyAuth _auth;
    private readonly SpotifyApi _api;
    private readonly LyricsService _lyricsService = new();
    private static readonly HttpClient Http = new();

    private Track? _track;
    public Track? Track { get => _track; private set => Set(ref _track, value); }

    private bool _isPlaying;
    public bool IsPlaying { get => _isPlaying; private set => Set(ref _isPlaying, value); }

    private ImageSource? _artwork;
    public ImageSource? Artwork { get => _artwork; private set => Set(ref _artwork, value); }

    private Color? _artworkColor;
    public Color? ArtworkColor { get => _artworkColor; private set => Set(ref _artworkColor, value); }

    private List<LyricLine> _lyrics = new();
    public List<LyricLine> Lyrics { get => _lyrics; private set => Set(ref _lyrics, value); }

    private bool _isConnected;
    public bool IsConnected { get => _isConnected; private set => Set(ref _isConnected, value); }

    private bool _shuffleOn;
    public bool ShuffleOn { get => _shuffleOn; private set => Set(ref _shuffleOn, value); }

    private string _repeatMode = "off";
    public string RepeatMode { get => _repeatMode; private set => Set(ref _repeatMode, value); }

    public bool HasLyrics => Lyrics.Count > 0;

    private CancellationTokenSource? _pollCts;
    private string? _currentTrackKey;
    private double _progressMs;
    private DateTime _progressAnchor = DateTime.UtcNow;

    private readonly Dictionary<string, (ImageSource Image, Color? Color)> _artworkCache = new();

    public NowPlayingModel(SpotifyAuth auth)
    {
        _auth = auth;
        _api = new SpotifyApi(auth);
        IsConnected = auth.IsConnected;
    }

    // MARK: - Polling lifecycle

    public void StartPolling()
    {
        if (_pollCts != null) return;
        var cts = new CancellationTokenSource();
        _pollCts = cts;
        _ = PollLoopAsync(cts.Token);
    }

    private async Task PollLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            await PollAsync();
            var interval = IsNearTrackBoundary() ? 800 : 2500;
            try { await Task.Delay(interval, token); }
            catch (TaskCanceledException) { break; }
        }
    }

    /// <summary>True in the last few seconds of a track, when a change is imminent.</summary>
    private bool IsNearTrackBoundary()
    {
        if (Track is not { } track || !IsPlaying) return false;
        var remaining = track.DurationMs / 1000.0 - EstimatedProgress();
        return remaining < 6;
    }

    public void StopPolling()
    {
        _pollCts?.Cancel();
        _pollCts = null;
    }

    private async Task PollAsync()
    {
        IsConnected = _auth.IsConnected;
        if (!_auth.IsConnected) return;
        try
        {
            var playing = await _api.CurrentlyPlayingAsync();
            if (playing?.Item is not { } track)
            {
                IsPlaying = false;
                return;
            }
            IsPlaying = playing.IsPlaying;
            _progressMs = playing.ProgressMs ?? 0;
            _progressAnchor = DateTime.UtcNow;
            Track = track;
            ShuffleOn = playing.ShuffleState ?? false;
            RepeatMode = playing.RepeatState ?? "off";

            var key = track.Key;
            if (key != _currentTrackKey)
            {
                _currentTrackKey = key;
                Lyrics = new List<LyricLine>();
                if (_artworkCache.TryGetValue(key, out var cached))
                {
                    Artwork = cached.Image;
                    ArtworkColor = cached.Color;
                }
                await LoadDetailsAsync(track, key);
                _ = PrefetchUpcomingAsync();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"MuseSaver: poll failed — {ex}");
        }
    }

    /// <summary>
    /// Loads a synthetic track (with real artwork + lyrics fetches) so the full lock
    /// screen UI can be exercised without a Spotify connection. Mirrors
    /// debugLoadSynthetic() from the macOS original.
    /// </summary>
    public async Task DebugLoadSyntheticAsync()
    {
        var synthetic = new Track
        {
            Id = "debug",
            Name = "Blinding Lights",
            DurationMs = 200_040,
            Artists = new List<Artist> { new() { Name = "The Weeknd" } },
            Album = new Album
            {
                Name = "After Hours",
                Images = new List<SpotifyImage>
                {
                    new() { Url = "https://i.scdn.co/image/ab67616d0000b2738863bc11d2aa12b54f5aeb36", Width = 640, Height = 640 }
                }
            }
        };
        Track = synthetic;
        IsPlaying = true;
        _progressMs = 45_000;
        _progressAnchor = DateTime.UtcNow;
        _currentTrackKey = "debug";
        await LoadDetailsAsync(synthetic, "debug");
    }

    private async Task LoadDetailsAsync(Track track, string key)
    {
        var lyricsTask = _lyricsService.LyricsForAsync(track);

        if (!_artworkCache.ContainsKey(key))
        {
            var loaded = await LoadImageAsync(track.AlbumArtUrl);
            if (loaded != null)
            {
                _artworkCache[key] = (loaded, ComputeAverageColorOnUiThread(loaded));
                if (_artworkCache.Count > 30)
                {
                    var drop = _artworkCache.Keys.FirstOrDefault(k => k != key);
                    if (drop != null) _artworkCache.Remove(drop);
                }
            }
        }

        if (key == _currentTrackKey && _artworkCache.TryGetValue(key, out var cached))
        {
            Artwork = cached.Image;
            ArtworkColor = cached.Color;
        }

        var loadedLyrics = await lyricsTask;
        if (key != _currentTrackKey) return;
        Lyrics = loadedLyrics;
        RaisePropertyChanged(nameof(HasLyrics));
        Debug.WriteLine($"MuseSaver: loaded '{track.Name}' — image={_artworkCache.ContainsKey(key)} lyrics={loadedLyrics.Count}");
    }

    private static async Task<BitmapImage?> LoadImageAsync(string? url)
    {
        if (string.IsNullOrEmpty(url)) return null;
        try
        {
            var bytes = await Http.GetByteArrayAsync(url);
            using var stream = new MemoryStream(bytes);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch { return null; }
    }

    /// <summary>
    /// RenderTargetBitmap/DrawingVisual are DispatcherObjects, so the render must
    /// happen on the UI thread even though this is invoked from a background poll.
    /// </summary>
    private static Color? ComputeAverageColorOnUiThread(BitmapSource source)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        return dispatcher == null || dispatcher.CheckAccess()
            ? AverageColor(source)
            : dispatcher.Invoke(() => AverageColor(source));
    }

    /// <summary>
    /// Derives a rich, legible background tone from the artwork's average color,
    /// boosting saturation and clamping brightness so it never reads as muddy black.
    /// </summary>
    private static Color? AverageColor(BitmapSource source)
    {
        try
        {
            var rtb = new RenderTargetBitmap(1, 1, 96, 96, PixelFormats.Pbgra32);
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawImage(source, new Rect(0, 0, 1, 1));
            }
            rtb.Render(visual);

            var pixels = new byte[4];
            rtb.CopyPixels(pixels, 4, 0);
            // Pbgra32 byte order: B, G, R, A (premultiplied).
            double a = pixels[3] / 255.0;
            if (a <= 0) a = 1;
            var b = pixels[0] / a / 255.0;
            var g = pixels[1] / a / 255.0;
            var r = pixels[2] / a / 255.0;

            RgbToHsb(Clamp01(r), Clamp01(g), Clamp01(b), out var h, out var s, out var v);
            var boostedS = Math.Min(s * 1.4, 1.0);
            var boostedV = Math.Max(Math.Min(v * 1.15, 0.72), 0.4);
            HsbToRgb(h, boostedS, boostedV, out var br, out var bg, out var bb);

            return Color.FromRgb((byte)(br * 255), (byte)(bg * 255), (byte)(bb * 255));
        }
        catch { return null; }
    }

    private static double Clamp01(double v) => Math.Max(0, Math.Min(1, v));

    private static void RgbToHsb(double r, double g, double b, out double h, out double s, out double v)
    {
        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        v = max;
        var delta = max - min;
        s = max <= 0 ? 0 : delta / max;
        if (delta <= 0.00001) { h = 0; return; }
        if (max == r) h = 60 * (((g - b) / delta) % 6);
        else if (max == g) h = 60 * (((b - r) / delta) + 2);
        else h = 60 * (((r - g) / delta) + 4);
        if (h < 0) h += 360;
    }

    private static void HsbToRgb(double h, double s, double v, out double r, out double g, out double b)
    {
        var c = v * s;
        var x = c * (1 - Math.Abs((h / 60) % 2 - 1));
        var m = v - c;
        double r1, g1, b1;
        if (h < 60) (r1, g1, b1) = (c, x, 0);
        else if (h < 120) (r1, g1, b1) = (x, c, 0);
        else if (h < 180) (r1, g1, b1) = (0, c, x);
        else if (h < 240) (r1, g1, b1) = (0, x, c);
        else if (h < 300) (r1, g1, b1) = (x, 0, c);
        else (r1, g1, b1) = (c, 0, x);
        r = r1 + m; g = g1 + m; b = b1 + m;
    }

    /// <summary>Prefetches lyrics + artwork for the next couple of queue tracks.</summary>
    private async Task PrefetchUpcomingAsync()
    {
        List<Track> upcoming;
        try { upcoming = await _api.UpcomingQueueAsync(); }
        catch { return; }

        foreach (var track in upcoming.Take(2))
        {
            var key = track.Key;
            _ = await _lyricsService.LyricsForAsync(track);
            if (!_artworkCache.ContainsKey(key))
            {
                var image = await LoadImageAsync(track.AlbumArtUrl);
                if (image != null) _artworkCache[key] = (image, ComputeAverageColorOnUiThread(image));
            }
        }
    }

    // MARK: - Playback commands

    /// <summary>Runs a player command with an optimistic UI update, then re-polls shortly after.</summary>
    private void Perform(Func<Task> action, Action optimistic)
    {
        optimistic();
        _ = Task.Run(async () =>
        {
            try { await action(); }
            catch (Exception ex) { Debug.WriteLine($"MuseSaver: player command failed — {ex}"); }
            await Task.Delay(350);
            await PollAsync();
        });
    }

    public void TogglePlayPause()
    {
        var wasPlaying = IsPlaying;
        var currentMs = EstimatedProgress() * 1000;
        Perform(
            () => wasPlaying ? _api.PauseAsync() : _api.PlayAsync(),
            () =>
            {
                _progressMs = currentMs;
                _progressAnchor = DateTime.UtcNow;
                IsPlaying = !wasPlaying;
            });
    }

    public void NextTrack() => Perform(() => _api.NextTrackAsync(), () => { });
    public void PreviousTrack() => Perform(() => _api.PreviousTrackAsync(), () => { });

    public void ToggleShuffle()
    {
        var target = !ShuffleOn;
        Perform(() => _api.SetShuffleAsync(target), () => ShuffleOn = target);
    }

    public void CycleRepeat()
    {
        var next = RepeatMode switch
        {
            "off" => "context",
            "context" => "track",
            _ => "off"
        };
        Perform(() => _api.SetRepeatAsync(next), () => RepeatMode = next);
    }

    /// <summary>Seeks to a fraction (0...1) of the current track.</summary>
    public void SeekToFraction(double fraction)
    {
        if (Track is not { } track) return;
        var clamped = Math.Max(0, Math.Min(1, fraction));
        var targetMs = (int)(clamped * track.DurationMs);
        Perform(
            () => _api.SeekAsync(targetMs),
            () =>
            {
                _progressMs = targetMs;
                _progressAnchor = DateTime.UtcNow;
            });
    }

    // MARK: - Playback position

    /// <summary>Estimated playback position in seconds, extrapolated from the last poll.</summary>
    public double EstimatedProgress()
    {
        var ms = _progressMs;
        if (IsPlaying) ms += (DateTime.UtcNow - _progressAnchor).TotalMilliseconds;
        return ms / 1000;
    }

    /// <summary>Fraction of the track elapsed (0...1) for the progress bar.</summary>
    public double ProgressFraction()
    {
        if (Track is not { DurationMs: > 0 } track) return 0;
        var fraction = EstimatedProgress() / (track.DurationMs / 1000.0);
        return Math.Max(0, Math.Min(1, fraction));
    }

    /// <summary>Index of the lyric line that should currently be highlighted.</summary>
    public int? CurrentLyricIndex()
    {
        if (Lyrics.Count == 0) return null;
        var now = EstimatedProgress();
        int? index = null;
        for (var i = 0; i < Lyrics.Count; i++)
        {
            if (Lyrics[i].Time <= now) index = i;
            else break;
        }
        return index;
    }
}
