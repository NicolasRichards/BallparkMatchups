# BallparkMatchups

iOS app (SwiftUI, Swift 6, iOS 17.0+) showing live batter-vs-pitcher matchups for MLB and MiLB games, built for use at the park. Free, no ads, uses the MLB Stats API. Developed on a Mac in Xcode. `README.md` has the architecture, polling schedule and data rules; read it before changing `GameViewModel`, `MLBAPIClient` or the push feed.

## Workflow

The owner runs Claude Code locally on a Mac, in the project folder, and opens the project in Xcode to find the latest changes. The owner does not use Terminal, so do not ask them to run git or shell commands; do the git work yourself.

- Cloud sessions are a different setup: they work on a fresh clone and push a `claude/...` branch to GitHub, which does not change the local folder until it is merged and pulled. If you are in a cloud session, there is no Xcode or simulator, so say plainly that the change is unbuilt and list what to check after building in Xcode.
- The project file `BallparkMatchups.xcodeproj` is committed; there is no `project.yml` in the repo. Avoid editing `project.pbxproj` by hand unless a change requires it (for example adding or removing a file), and say so when you do.
- A shared Xcode scheme named `BallparkMatchups` exists, and command-line builds work on the owner's Mac: `xcodebuild -project BallparkMatchups.xcodeproj -scheme BallparkMatchups -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` (Debug and Release both verified). Do not report a build as passing unless one actually ran.
- Optional check: `cd Tools/swift-verify && swift test` (the push-feed patch core; it symlinks `BallparkMatchups/API/JSONValue.swift`). Also `Tools/diffpatch-verify` (see its README).

## Layout

- `BallparkMatchups/API`: network (`MLBAPIClient` is an actor), Gameday websocket, `JSONValue` (raw JSON tree plus RFC 6902 patching)
- `BallparkMatchups/ViewModels`: `AppViewModel` (top-level state) and `GameViewModel` (per-game polling, diffing, split selection)
- `BallparkMatchups/Services`: feature flags, location, venue cache, `SplitPriorityEngine`
- `BallparkMatchups/Models`, `Views`, `Resources` (`venues.json`, `situationCodes.json`)
- `Tools/`: verification harnesses and working notes (`PUSH-FEED-STATUS.md`, `AFL-SUPPORT-NOTES.md`)
- `docs/`, `AppStoreScreenshots/`: marketing site and App Store assets

## Conventions

- "Today" rolls over at 3 a.m. Eastern for every venue (`todayDateString()` in `AppViewModel` and `VenueCache`), so late West Coast games stay listed after local midnight. It is not the venue's or the device's time zone.
- Split display thresholds live in `Models/SplitThresholds.swift`; the README "Data Notes" section describes the intended values.
- Version bumps are their own commits, titled like `Bump to 1.6 (8)`.
- Commit messages are short imperative sentences describing what changed.

## Known doc drift

The README and `Tools/PUSH-FEED-STATUS.md` say the push feed is off by default. The code (`Services/FeatureFlags.swift`) defaults it to on, matching commit "Turn the push feed on by default, in every build". Trust the code, and fix the docs when touching them.
