using System.IO;
using System.Text.Json;

namespace MuseSaverWin.Support;

/// <summary>App preferences persisted as JSON under %LOCALAPPDATA%\MuseSaver.</summary>
internal static class Preferences
{
    private sealed class Data
    {
        public bool ShowOnUnlock { get; set; } = true;
    }

    private static readonly string FilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "MuseSaver", "prefs.json");

    private static Data _data = Load();

    private static Data Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var json = File.ReadAllText(FilePath);
                var loaded = JsonSerializer.Deserialize<Data>(json);
                if (loaded != null) return loaded;
            }
        }
        catch
        {
            // Corrupt or unreadable prefs file — fall back to defaults.
        }
        return new Data();
    }

    private static void Save()
    {
        try
        {
            var dir = Path.GetDirectoryName(FilePath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(_data));
        }
        catch
        {
            // Best-effort persistence; nothing user-actionable to do on failure.
        }
    }

    /// <summary>Whether the lock screen should appear automatically when Windows unlocks.</summary>
    public static bool ShowOnUnlock
    {
        get => _data.ShowOnUnlock;
        set
        {
            _data.ShowOnUnlock = value;
            Save();
        }
    }
}
