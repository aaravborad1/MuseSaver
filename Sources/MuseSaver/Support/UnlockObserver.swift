import AppKit

/// Watches for the user unlocking the Mac (after sleep / power button / lock) and
/// fires a callback. macOS apps cannot draw on the secure lock screen itself, so
/// showing MuseSaver at the moment of unlock is the closest supported behavior.
final class UnlockObserver {
    var onUnlock: (() -> Void)?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onUnlock?()
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
