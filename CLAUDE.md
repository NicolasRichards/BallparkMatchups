# BallparkMatchups

iOS app (SwiftUI, Swift 6, iOS 17.0+) showing live batter-vs-pitcher matchups for MLB and MiLB games, built for use at the park. Free, no ads, uses the MLB Stats API. Developed on a Mac in Xcode. `README.md` has the architecture, polling schedule and data rules; read it before changing `GameViewModel`, `MLBAPIClient` or the push feed.

## Build and test

- Open `BallparkMatchups.xcodeproj` in Xcode and build. The project file is committed; there is no `project.yml` in the repo.
- Push-feed patch core: `cd Tools/swift-verify && swift test`. It symlinks `BallparkMatchups/API/JSONValue.swift`, so it compiles the same file the app ships.
- Patch algorithm check against captured MLB traffic: `Tools/diffpatch-verify` (see its README).
- Xcode and the iOS simulator are not available in the cloud container. Do not claim the app builds or runs unless that was actually verified on a Mac.

## Layout

- `BallparkMatchups/API`: network (`MLBAPIClient` is an actor), Gameday websocket, `JSONValue` (raw JSON tree plus RFC 6902 patching)
- `BallparkMatchups/ViewModels`: `AppViewModel` (top-level state) and `GameViewModel` (per-game polling, diffing, split selection)
- `BallparkMatchups/Services`: feature flags, location, venue cache, `SplitPriorityEngine`
- `BallparkMatchups/Models`, `Views`, `Resources` (`venues.json`, `situationCodes.json`)
- `Tools/`: verification harnesses and working notes (`PUSH-FEED-STATUS.md`, `AFL-SUPPORT-NOTES.md`)
- `docs/`, `AppStoreScreenshots/`: marketing site and App Store assets

## Conventions

- Venue timezone, not device timezone, decides what "today" is.
- Split display thresholds live in `Models/SplitThresholds.swift`; the README "Data Notes" section describes the intended values.
- Version bumps are their own commits, titled like `Bump to 1.6 (8)`.
- Commit messages are short imperative sentences describing what changed.

## Known doc drift

The README and `Tools/PUSH-FEED-STATUS.md` say the push feed is off by default. The code (`Services/FeatureFlags.swift`) defaults it to on, matching commit "Turn the push feed on by default, in every build". Trust the code, and fix the docs when touching them.
