namespace MuseSaverWin.LockScreen;

/// <summary>
/// Creates and tears down the fullscreen borderless lock screen window and starts /
/// stops polling in step with its visibility.
/// </summary>
internal sealed class LockScreenWindowController
{
    private readonly NowPlayingModel _model;
    private LockScreenWindow? _window;

    public LockScreenWindowController(NowPlayingModel model)
    {
        _model = model;
    }

    public void Toggle()
    {
        if (_window == null) Show();
        else Hide();
    }

    public void Show()
    {
        if (_window != null) return;

        var window = new LockScreenWindow(_model);
        window.Dismissed += Hide;

        _window = window;
        _model.StartPolling();
        window.Show();
        window.Activate();
    }

    public void Hide()
    {
        _model.StopPolling();
        _window?.Close();
        _window = null;
    }
}
