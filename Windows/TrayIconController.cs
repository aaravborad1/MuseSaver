using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using MuseSaverWin.LockScreen;
using MuseSaverWin.Spotify;
using MuseSaverWin.Support;
using Application = System.Windows.Application;
using ContextMenuStrip = System.Windows.Forms.ContextMenuStrip;
using MenuItem = System.Windows.Forms.ToolStripMenuItem;

namespace MuseSaverWin;

/// <summary>
/// System-tray icon + menu — the Windows equivalent of the NSStatusItem menu bar
/// controller on macOS.
/// </summary>
internal sealed class TrayIconController : IDisposable
{
    private readonly NotifyIcon _notifyIcon;
    private readonly SpotifyAuth _auth;
    private readonly LockScreenWindowController _windowController;

    public TrayIconController(SpotifyAuth auth, LockScreenWindowController windowController)
    {
        _auth = auth;
        _windowController = windowController;

        _notifyIcon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "MuseSaver",
            Visible = true
        };
        _notifyIcon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) _windowController.Show();
        };

        RebuildMenu();
        _auth.ConnectionChanged += RebuildMenu;
    }

    private static Icon LoadIcon()
    {
        try
        {
            var uri = new Uri("pack://application:,,,/Resources/tray.ico");
            var streamInfo = Application.GetResourceStream(uri);
            if (streamInfo != null) return new Icon(streamInfo.Stream);
        }
        catch { /* fall back to a generated icon below */ }
        return GeneratedFallbackIcon();
    }

    /// <summary>A simple generated glyph so the app has a visible tray icon even
    /// without a bundled .ico resource.</summary>
    private static Icon GeneratedFallbackIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.Clear(Color.Transparent);
            using var brush = new SolidBrush(Color.FromArgb(255, 138, 92, 246));
            g.FillEllipse(brush, 2, 2, 28, 28);
            using var font = new Font("Segoe UI", 14, System.Drawing.FontStyle.Bold);
            using var textBrush = new SolidBrush(Color.White);
            g.DrawString("M", font, textBrush, 7, 5);
        }
        return Icon.FromHandle(bitmap.GetHicon());
    }

    private void RebuildMenu()
    {
        var menu = new ContextMenuStrip();

        if (_auth.IsConnected)
        {
            var status = new MenuItem("Spotify Connected") { Enabled = false };
            menu.Items.Add(status);
        }
        else
        {
            var connect = new MenuItem("Connect Spotify…");
            connect.Click += (_, _) => _auth.Connect();
            menu.Items.Add(connect);
        }

        menu.Items.Add(new ToolStripSeparator());

        var show = new MenuItem("Show Lock Screen  (Alt+Shift+L)");
        show.Click += (_, _) => _windowController.Show();
        menu.Items.Add(show);

        var unlockToggle = new MenuItem("Show When Windows Unlocks") { Checked = Preferences.ShowOnUnlock };
        unlockToggle.Click += (_, _) =>
        {
            Preferences.ShowOnUnlock = !Preferences.ShowOnUnlock;
            RebuildMenu();
        };
        menu.Items.Add(unlockToggle);

        if (_auth.IsConnected)
        {
            var disconnect = new MenuItem("Disconnect Spotify");
            disconnect.Click += (_, _) => _auth.Disconnect();
            menu.Items.Add(disconnect);
        }

        menu.Items.Add(new ToolStripSeparator());

        var quit = new MenuItem("Quit MuseSaver");
        quit.Click += (_, _) => Application.Current.Shutdown();
        menu.Items.Add(quit);

        _notifyIcon.ContextMenuStrip = menu;
    }

    public void Dispose()
    {
        _auth.ConnectionChanged -= RebuildMenu;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
    }
}
