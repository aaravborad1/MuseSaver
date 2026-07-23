using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using MuseSaverWin.Lyrics;
using KeyEventArgs = System.Windows.Input.KeyEventArgs;
using Color = System.Windows.Media.Color;
using Image = System.Windows.Controls.Image;

namespace MuseSaverWin.LockScreen;

/// <summary>
/// The fullscreen lock screen window: a background tinted from the album art, a
/// clock, the artwork, a frosted mini-player, and time-synced lyrics.
/// Mirrors LockScreenView.swift + LockScreenWindow.swift from the macOS original.
/// </summary>
internal partial class LockScreenWindow : Window
{
    private readonly NowPlayingModel _model;
    private readonly DispatcherTimer _clockTimer;
    private readonly DispatcherTimer _lyricsTimer;
    private readonly DispatcherTimer _progressTimer;

    private bool _showDetails = true;
    private int? _currentLyricIndex;

    // Change-detection so PropertyChanged notifications that don't actually touch
    // artwork/tint/track (e.g. shuffle toggling) don't re-trigger a crossfade —
    // that was making everything feel choppy, since every model update replayed
    // the transition even when nothing visually changed.
    private ImageSource? _lastArtwork;
    private Color? _lastTint;
    private string? _lastLyricsTrackKey;
    private readonly SolidColorBrush _topGlowBrush = new(Colors.Transparent);
    private readonly SolidColorBrush _sideGlowBrush = new(Colors.Transparent);

    public event Action? Dismissed;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;

    public LockScreenWindow(NowPlayingModel model)
    {
        _model = model;
        InitializeComponent();

        // Persistent brushes for the clock glow layers so tint changes can be
        // animated (BeginAnimation needs a stable brush instance to animate, not
        // a freshly replaced one each refresh).
        TopTimeGlow.Foreground = _topGlowBrush;
        SideTimeGlow.Foreground = _sideGlowBrush;

        // The window's final size/position is set in device pixels once the native
        // HWND exists (see PositionOnCurrentScreen) rather than through WPF's
        // DIP-based Left/Top/Width/Height here — those are logical units, and
        // feeding them raw monitor pixel values double-scales on any display that
        // isn't at 100% Windows scaling, which is what produced the oversized,
        // top-clipped layout on a real monitor. The app declares Per-Monitor-V2 DPI
        // awareness (app.manifest) so this positions correctly on whichever screen
        // — and whatever resolution/scaling — the window ends up on, including on
        // a different PC than this one.
        SourceInitialized += (_, _) => PositionOnCurrentScreen();

        _model.PropertyChanged += Model_PropertyChanged;

        _clockTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _clockTimer.Tick += (_, _) => UpdateClock();

        _lyricsTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        _lyricsTimer.Tick += (_, _) => UpdateLyricsHighlight();

        _progressTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        _progressTimer.Tick += (_, _) => UpdateProgress();

        Loaded += (_, _) =>
        {
            UpdateClock();
            RefreshAll();
            Keyboard.Focus(this);
        };
        Closed += (_, _) =>
        {
            _clockTimer.Stop();
            _lyricsTimer.Stop();
            _progressTimer.Stop();
            _model.PropertyChanged -= Model_PropertyChanged;
        };

        _clockTimer.Start();
        _lyricsTimer.Start();
        _progressTimer.Start();

        PreviewKeyDown += LockScreenWindow_PreviewKeyDown;
    }

    /// <summary>
    /// Sizes and positions the window to exactly cover the monitor the user is
    /// currently on (the one under the mouse cursor — the closest Windows analogue
    /// to NSScreen.main), in physical device pixels via SetWindowPos. This is what
    /// makes the lock screen render correctly regardless of monitor resolution or
    /// Windows display-scaling percentage, on this PC or any other.
    /// </summary>
    private void PositionOnCurrentScreen()
    {
        var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
        var bounds = screen.Bounds;
        var hwnd = new WindowInteropHelper(this).Handle;
        SetWindowPos(hwnd, IntPtr.Zero, bounds.Left, bounds.Top, bounds.Width, bounds.Height,
            SWP_NOZORDER | SWP_NOACTIVATE);

        ApplyClockScale(bounds.Width);
    }

    // Baseline point sizes, tuned for a 1920px-wide screen — the clock scales up
    // from here for wider/higher-resolution monitors (e.g. a 27" QHD/curved
    // display) instead of staying a fixed, increasingly-small-looking size.
    private const double TopDateBase = 28;
    private const double TopTimeBase = 130;
    private const double SideDateBase = 34;
    private const double SideTimeBase = 210;

    private void ApplyClockScale(int screenWidthPx)
    {
        var scale = Math.Clamp(screenWidthPx / 1920.0, 0.85, 2.5);

        TopDateText.FontSize = TopDateBase * scale;
        TopTimeGlow.FontSize = TopTimeBase * scale;
        TopTimeText.FontSize = TopTimeBase * scale;
        TopTimeHighlight.FontSize = TopTimeBase * scale;

        SideDateText.FontSize = SideDateBase * scale;
        SideTimeGlow.FontSize = SideTimeBase * scale;
        SideTimeText.FontSize = SideTimeBase * scale;
        SideTimeHighlight.FontSize = SideTimeBase * scale;
    }

    // MARK: - Model updates

    private void Model_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(RefreshAll);
    }

    private static readonly TimeSpan ArtworkCrossfadeDuration = TimeSpan.FromMilliseconds(450);
    private static readonly TimeSpan BackgroundCrossfadeDuration = TimeSpan.FromMilliseconds(700);
    private static readonly TimeSpan TintTransitionDuration = TimeSpan.FromMilliseconds(700);

    private void RefreshAll()
    {
        var track = _model.Track;
        NothingPlayingText.Visibility = track == null ? Visibility.Visible : Visibility.Collapsed;

        // Only crossfade when the artwork actually changed — this used to run
        // (and re-fade) on every model update, including ones unrelated to
        // artwork, which is what made things feel choppy.
        if (!ReferenceEquals(_model.Artwork, _lastArtwork))
        {
            _lastArtwork = _model.Artwork;
            CrossfadeImage(BlurredArtwork, _model.Artwork, 0.5, BackgroundCrossfadeDuration);
            CrossfadeImage(ArtworkImage, _model.Artwork, 1.0, ArtworkCrossfadeDuration);
            CrossfadeImage(ThumbnailImage, _model.Artwork, 1.0, ArtworkCrossfadeDuration);
            ArtworkPlaceholder.Visibility = _model.Artwork == null ? Visibility.Visible : Visibility.Collapsed;
        }

        var tint = _model.ArtworkColor ?? Color.FromRgb(31, 31, 31);
        if (_lastTint != tint)
        {
            _lastTint = tint;
            AnimateColor(TintStop1, GradientStop.ColorProperty, Color.FromArgb(250, tint.R, tint.G, tint.B), TintTransitionDuration);
            AnimateColor(TintStop2, GradientStop.ColorProperty, Color.FromArgb(204, tint.R, tint.G, tint.B), TintTransitionDuration);
            AnimateColor(TopTimeTintStop, GradientStop.ColorProperty, Color.FromArgb(217, tint.R, tint.G, tint.B), TintTransitionDuration);
            AnimateColor(SideTimeTintStop, GradientStop.ColorProperty, Color.FromArgb(217, tint.R, tint.G, tint.B), TintTransitionDuration);
            AnimateColor(_topGlowBrush, SolidColorBrush.ColorProperty, tint, TintTransitionDuration);
            AnimateColor(_sideGlowBrush, SolidColorBrush.ColorProperty, tint, TintTransitionDuration);
        }

        TrackTitleText.Text = track?.Name ?? "";
        TrackArtistText.Text = track?.ArtistNames ?? "";

        PlayPauseButton.Content = _model.IsPlaying ? "" : ""; // pause : play
        ShuffleButton.Opacity = _model.ShuffleOn ? 1.0 : 0.45;
        RepeatButton.Content = _model.RepeatMode == "track" ? "" : ""; // repeat-one : repeat
        RepeatButton.Opacity = _model.RepeatMode == "off" ? 0.45 : 1.0;

        var lyricsKey = track?.Key;
        if (lyricsKey != _lastLyricsTrackKey)
        {
            _lastLyricsTrackKey = lyricsKey;
            _currentLyricIndex = null;
            AnimateLyricsTransition();
        }
        UpdateProgress();
    }

    /// <summary>Fades an Image out, swaps its Source, then fades it back in — avoids
    /// the hard instant-swap "flash" when album art changes between tracks.</summary>
    private static void CrossfadeImage(Image image, ImageSource? newSource, double targetOpacity, TimeSpan duration)
    {
        var outMs = duration.TotalMilliseconds * 0.35;
        var inMs = duration.TotalMilliseconds * 0.65;
        var fadeOut = new DoubleAnimation(0, TimeSpan.FromMilliseconds(outMs))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn }
        };
        fadeOut.Completed += (_, _) =>
        {
            image.Source = newSource;
            var fadeIn = new DoubleAnimation(targetOpacity, TimeSpan.FromMilliseconds(inMs))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
            };
            image.BeginAnimation(UIElement.OpacityProperty, fadeIn);
        };
        image.BeginAnimation(UIElement.OpacityProperty, fadeOut);
    }

    private static void AnimateColor(Animatable target, DependencyProperty property, Color to, TimeSpan duration)
    {
        var animation = new ColorAnimation(to, duration)
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut }
        };
        target.BeginAnimation(property, animation);
    }

    private void UpdateClock()
    {
        var now = DateTime.Now;
        var date = now.ToString("dddd, MMMM d");
        var time = now.ToString("HH:mm");

        TopDateText.Text = date;
        TopTimeGlow.Text = time;
        TopTimeText.Text = time;
        TopTimeHighlight.Text = time;

        SideDateText.Text = date;
        SideTimeGlow.Text = time;
        SideTimeText.Text = time;
        SideTimeHighlight.Text = time;
    }

    private void UpdateProgress()
    {
        var fraction = _model.ProgressFraction();
        var maxWidth = ProgressTrack.ActualWidth;
        if (maxWidth <= 0) return;
        ProgressFill.Width = Math.Max(0, Math.Min(1, fraction)) * maxWidth;
    }

    // MARK: - Lyrics

    private void UpdateLyricsHighlight()
    {
        var index = _model.CurrentLyricIndex();
        if (index == _currentLyricIndex) return;
        _currentLyricIndex = index;
        AnimateLyricsTransition();
    }

    /// <summary>
    /// Fades the lyrics panel out, rebuilds it for the new current line, then fades
    /// (and slides slightly) back in — mirrors the Swift original's animated color
    /// crossfade + scrollTo, so a line change reads as a transition instead of a
    /// hard cut.
    /// </summary>
    private void AnimateLyricsTransition()
    {
        var fadeOut = new DoubleAnimation(0, TimeSpan.FromMilliseconds(140))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn }
        };
        fadeOut.Completed += (_, _) =>
        {
            RenderLyricsWindow();
            LyricsPanelTransform.Y = 10;
            var fadeIn = new DoubleAnimation(1, TimeSpan.FromMilliseconds(280))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
            };
            var slideIn = new DoubleAnimation(0, TimeSpan.FromMilliseconds(280))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
            };
            LyricsPanel.BeginAnimation(UIElement.OpacityProperty, fadeIn);
            LyricsPanelTransform.BeginAnimation(TranslateTransform.YProperty, slideIn);
        };
        LyricsPanel.BeginAnimation(UIElement.OpacityProperty, fadeOut);
    }

    /// <summary>
    /// Renders a small centered window of lyric lines around the current one —
    /// two lines before, the current line (bigger + bold, like the macOS original),
    /// two lines after — rebuilt fresh each time the current index changes.
    /// </summary>
    private void RenderLyricsWindow()
    {
        LyricsPanel.Children.Clear();
        var lyrics = _model.Lyrics;
        if (lyrics.Count == 0) return;

        var current = _currentLyricIndex ?? -1;
        int start, end;
        if (current < 0)
        {
            start = 0;
            end = Math.Min(lyrics.Count - 1, 3);
        }
        else
        {
            start = Math.Max(0, current - 2);
            end = Math.Min(lyrics.Count - 1, current + 2);
        }

        for (var i = start; i <= end; i++)
        {
            var isCurrent = i == current;
            var distance = Math.Abs(i - current);
            var line = lyrics[i];

            byte alpha = isCurrent ? (byte)255 : i < current ? (byte)90 : (byte)150;
            double fontSize = isCurrent ? 36 : distance == 1 ? 27 : 22;

            var tb = new TextBlock
            {
                Text = string.IsNullOrEmpty(line.Text) ? "♪" : line.Text,
                TextWrapping = TextWrapping.Wrap,
                // Explicit width (not just a parent constraint) guarantees wrapping —
                // a Left-aligned ancestor can otherwise offer infinite measure width.
                Width = 560,
                TextAlignment = TextAlignment.Left,
                FontSize = fontSize,
                FontWeight = isCurrent ? FontWeights.Bold : FontWeights.SemiBold,
                Foreground = new SolidColorBrush(Color.FromArgb(alpha, 255, 255, 255)),
                Margin = new Thickness(0, 0, 0, isCurrent ? 18 : 14)
            };
            if (isCurrent)
            {
                tb.Effect = new System.Windows.Media.Effects.DropShadowEffect
                {
                    Color = Colors.Black, Opacity = 0.4, BlurRadius = 10, ShadowDepth = 2
                };
            }
            LyricsPanel.Children.Add(tb);
        }
    }

    // MARK: - Declutter / dismissal

    private void Artwork_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        _showDetails = !_showDetails;
        ApplyDeclutter();
        e.Handled = true;
    }

    private void ApplyDeclutter()
    {
        TopClockPanel.Opacity = _showDetails ? 1 : 0;
        MiniPlayer.Opacity = _showDetails ? 1 : 0;
        MiniPlayer.IsHitTestVisible = _showDetails;
        LyricsContainer.Opacity = _showDetails ? 1 : 0;
        SideClockPanel.Visibility = _showDetails ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Background_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        Dismissed?.Invoke();
    }

    private void LockScreenWindow_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Dismissed?.Invoke();
            e.Handled = true;
        }
    }

    // MARK: - Transport controls

    private void ProgressTrack_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var x = e.GetPosition(ProgressTrack).X;
        var fraction = x / ProgressTrack.ActualWidth;
        _model.SeekToFraction(fraction);
        e.Handled = true;
    }

    private void ShuffleButton_Click(object sender, RoutedEventArgs e) => _model.ToggleShuffle();
    private void PrevButton_Click(object sender, RoutedEventArgs e) => _model.PreviousTrack();
    private void PlayPauseButton_Click(object sender, RoutedEventArgs e) => _model.TogglePlayPause();
    private void NextButton_Click(object sender, RoutedEventArgs e) => _model.NextTrack();
    private void RepeatButton_Click(object sender, RoutedEventArgs e) => _model.CycleRepeat();
}
