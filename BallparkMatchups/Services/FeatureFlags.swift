import Foundation

/// Runtime switches for work that is not ready to be the default.
enum FeatureFlags {
    private static let pushFeedKey = "feature.pushFeed.enabled"

    /// Drive the live card from the Gameday socket plus `diffPatch` instead of
    /// polling the whole game object every five seconds.
    ///
    /// Off by default. The push path cannot be exercised outside a live game, so
    /// it stays opt-in until it has been watched through real ones — turn it on
    /// from the debug overlay and compare against the polling backstop.
    static var pushFeedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: pushFeedKey) }
        set { UserDefaults.standard.set(newValue, forKey: pushFeedKey) }
    }
}
