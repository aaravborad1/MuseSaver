using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace MuseSaverWin.Support;

/// <summary>
/// Registers a system-wide hotkey (Alt+Shift+L) via the Win32 RegisterHotKey API —
/// the Windows equivalent of the Carbon hotkey used on macOS. Works without any
/// special permissions.
/// </summary>
internal sealed class HotKeyManager : IDisposable
{
    private const int WM_HOTKEY = 0x0312;
    private const int HOTKEY_ID = 0x4D53; // 'MS'
    private const uint MOD_ALT = 0x0001;
    private const uint MOD_SHIFT = 0x0004;
    private const uint VK_L = 0x4C;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private HwndSource? _source;

    public event Action? HotKeyPressed;

    public void Register()
    {
        var parameters = new HwndSourceParameters("MuseSaverHotKeyWindow")
        {
            WindowStyle = 0,
            Width = 0,
            Height = 0,
            ParentWindow = new IntPtr(-3) // HWND_MESSAGE: message-only window
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WndProc);

        RegisterHotKey(_source.Handle, HOTKEY_ID, MOD_ALT | MOD_SHIFT, VK_L);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_HOTKEY && wParam.ToInt32() == HOTKEY_ID)
        {
            HotKeyPressed?.Invoke();
            handled = true;
        }
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_source != null)
        {
            UnregisterHotKey(_source.Handle, HOTKEY_ID);
            _source.RemoveHook(WndProc);
            _source.Dispose();
            _source = null;
        }
    }
}
