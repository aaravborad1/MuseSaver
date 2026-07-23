using Microsoft.Win32;

namespace MuseSaverWin.Support;

/// <summary>
/// Watches for the Windows session unlocking and fires a callback — the Windows
/// equivalent of watching for "com.apple.screenIsUnlocked" on macOS.
/// </summary>
internal sealed class SessionUnlockObserver : IDisposable
{
    public event Action? Unlocked;

    public SessionUnlockObserver()
    {
        SystemEvents.SessionSwitch += OnSessionSwitch;
    }

    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionUnlock)
        {
            Unlocked?.Invoke();
        }
    }

    public void Dispose()
    {
        SystemEvents.SessionSwitch -= OnSessionSwitch;
    }
}
