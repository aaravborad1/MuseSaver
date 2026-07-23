# MuseSaver (Windows)

A native **Windows 11** port of MuseSaver — a fullscreen, iOS-style lock screen for
whatever is currently playing on Spotify: blurred album art, a big dynamic-glass
clock, the track title and artist, and time-synced lyrics.

This is a from-scratch rewrite of the [macOS version](../README.md) using native
Windows APIs — not a wrapper or a port of the Swift/AppKit code. It reproduces the
same behavior and visual design using:

| macOS original | Windows equivalent |
|---|---|
| Swift, AppKit, SwiftUI | C#, WPF (.NET 8) |
| NSStatusItem (menu bar) | `NotifyIcon` (system tray) |
| Keychain | Windows Credential Manager |
| Carbon hotkey API | `RegisterHotKey` (Win32) |
| `com.apple.screenIsUnlocked` notification | `SystemEvents.SessionSwitch` |

Built entirely with **C#, WPF, and Windows Forms interop** (for the tray icon) — no
third-party UI dependencies.

---

## 1. Register a Spotify app

Same as the macOS version:

1. Go to the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
   and click **Create app**.
2. Give it any name and description.
3. Under **Redirect URIs**, add exactly:

   ```
   http://127.0.0.1:8888/callback
   ```

4. For **Which API/SDKs are you planning to use?**, select **Web API**.
5. Save, then open the app's **Settings** and copy the **Client ID**.

### Provide the Client ID to MuseSaver

Either edit `Spotify/SpotifyConfig.cs` and replace the fallback client ID, or set an
environment variable before launching (this takes precedence):

```powershell
$env:SPOTIFY_CLIENT_ID = "xxxxxxxxxxxxxxxxxxxxxxxx"
```

---

## 2. Build & run

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download).

```powershell
cd Windows
dotnet run
```

Or open `MuseSaverWin.csproj` in Visual Studio / Rider and run it there.

The app has no taskbar entry — look for the icon in the **system tray**.

---

## 3. Use it

1. Click the tray icon → **Connect Spotify…**. Your browser opens the Spotify
   consent screen; approve it and you'll see a "MuseSaver connected" page.
2. Start playing something in Spotify.
3. Click the tray icon → **Show Lock Screen**, or press **Alt+Shift+L** from
   anywhere.
4. Tap the album art to declutter — a large clock takes over next to the artwork.
   Press **Escape** or click outside the artwork to dismiss.

The lock screen automatically sizes itself to whichever monitor you're currently on
(by cursor position), scaling the clock proportionally to that screen's resolution.

---

## Project layout

```
Windows/
├── App.xaml / App.xaml.cs              # Entry point, wires everything together
├── TrayIconController.cs               # NotifyIcon + menu
├── Support/
│   ├── CredentialStore.cs              # Refresh-token storage (Credential Manager)
│   ├── HotKeyManager.cs                # Global hotkey (RegisterHotKey)
│   ├── SessionUnlockObserver.cs        # Windows-unlock detection
│   ├── Preferences.cs                  # Persisted app settings
│   └── FormEncoding.cs                 # PKCE / form-encoding helpers
├── Spotify/
│   ├── SpotifyConfig.cs                # Client ID, redirect URI, scopes
│   ├── LocalCallbackServer.cs          # Catches the OAuth redirect (HttpListener)
│   ├── SpotifyAuth.cs                  # PKCE flow + token refresh
│   ├── SpotifyModels.cs                # JSON API models
│   └── SpotifyApi.cs                   # currently-playing + playback endpoints
├── Lyrics/
│   └── LyricsService.cs                # lrclib fetch + LRC parse + disk cache
└── LockScreen/
    ├── NowPlayingModel.cs              # Polling + playback estimation store
    ├── LockScreenWindow.xaml(.cs)      # Fullscreen borderless lock-screen UI
    └── LockScreenWindowController.cs   # Window lifecycle
```

## Notes & limitations

- Same Spotify Premium requirement as the macOS version: playback controls
  (play/pause/skip/seek) need a Premium account — the Web API returns 403 on Free.
- Lyrics come from lrclib's community database — coverage varies by track.
- Requires Windows 10/11 with .NET 8 Desktop Runtime (or build with the SDK).

## License

MIT, same as the macOS version. Do whatever you like.
