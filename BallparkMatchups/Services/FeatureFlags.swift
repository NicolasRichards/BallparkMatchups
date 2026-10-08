import Foundation

/// Runtime switches for work that is not ready to be the default.
enum FeatureFlags {
    private static let pushFeedKey = "feature.pushFeed.enabled"

    /// Drive the live card from the Gameday socket plus `diffPatch` instead of
    /// polling the whole game object every five seconds.
    ///
    /// **On by default, in every build.** It was opt-in while it could not be
    /// exercised outside a live game; it has since been watched through four
    /// complete ones with no patch failures, saving 80–89% of the bytes
    /// polling the same games would have cost, at roughly 3% of battery an
    /// hour with the screen on.
    ///
    /// Failure degrades rather than breaks. Three consecutive patch failures
    /// disable the push path for the session, `pushIsHealthy` refuses to back
    /// the poll loop off while patches are not arriving, and polling runs the
    /// whole time as a backstop — so the worst case is the behaviour that
    /// shipped before this existed.
    ///
    /// The debug overlay can still switch it off in a build run from Xcode,
    /// to compare against that backstop. A value saved there persists, which
    /// is the point; archived builds have no overlay and always get the
    /// default.
    static var pushFeedEnabled: Bool {
        get {
            #if DEBUG
            // `bool(forKey:)` cannot tell "never set" from "set to false",
            // and the default has to be on.
            UserDefaults.standard.object(forKey: pushFeedKey) as? Bool ?? true
            #else
            true
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: pushFeedKey) }
    }
}
