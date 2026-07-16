import Foundation

/// App preferences persisted in UserDefaults.
enum Preferences {
    private static let showOnUnlockKey = "showOnUnlock"

    /// Whether the lock screen should appear automatically when the Mac unlocks.
    /// Defaults to true.
    static var showOnUnlock: Bool {
        get {
            if UserDefaults.standard.object(forKey: showOnUnlockKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: showOnUnlockKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showOnUnlockKey) }
    }
}
