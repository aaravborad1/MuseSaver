using System.Windows;
using MuseSaverWin.LockScreen;
using MuseSaverWin.Spotify;
using MuseSaverWin.Support;
using Application = System.Windows.Application;

namespace MuseSaverWin;

/// <summary>
/// MuseSaver runs as a tray-only app: no main window, no taskbar entry.
/// Mirrors AppDelegate.swift from the macOS original.
/// </summary>
public partial class App : Application
{
    private SpotifyAuth? _auth;
    private NowPlayingModel? _model;
    private LockScreenWindowController? _windowController;
    private TrayIconController? _trayIcon;
    private HotKeyManager? _hotKey;
    private SessionUnlockObserver? _unlockObserver;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var auth = new SpotifyAuth();
        var model = new NowPlayingModel(auth);
        var windowController = new LockScreenWindowController(model);

        _auth = auth;
        _model = model;
        _windowController = windowController;
        _trayIcon = new TrayIconController(auth, windowController);

        // Global hotkey (Alt+Shift+L) toggles the lock screen from anywhere.
        var hotKey = new HotKeyManager();
        hotKey.HotKeyPressed += () => windowController.Toggle();
        hotKey.Register();
        _hotKey = hotKey;

        // Show automatically when Windows unlocks (optional, on by default).
        var unlockObserver = new SessionUnlockObserver();
        unlockObserver.Unlocked += () =>
        {
            if (Preferences.ShowOnUnlock) windowController.Show();
        };
        _unlockObserver = unlockObserver;

        // Diagnostic: MUSESAVER_DEBUG_SHOW=1 opens the lock screen right after
        // launch (with synthetic data if not connected) so it can be verified
        // visually, mirroring the macOS original's debug hooks.
        if (Environment.GetEnvironmentVariable("MUSESAVER_DEBUG_SHOW") == "1")
        {
            var fake = Environment.GetEnvironmentVariable("MUSESAVER_DEBUG_FAKE") == "1";
            var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += (_, _) =>
            {
                timer.Stop();
                windowController.Show();
                if (fake) _ = model.DebugLoadSyntheticAsync();
            };
            timer.Start();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _hotKey?.Dispose();
        _unlockObserver?.Dispose();
        _trayIcon?.Dispose();
        base.OnExit(e);
    }
}
