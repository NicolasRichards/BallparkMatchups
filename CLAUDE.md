# BallparkMatchups

iOS app (SwiftUI, Swift 6, iOS 17.0+) showing live batter-vs-pitcher matchups for MLB and MiLB games, built for use at the park. Free, no ads, uses the MLB Stats API. Developed on a Mac in Xcode. `README.md` has the architecture, polling schedule and data rules; read it before changing `GameViewModel`, `MLBAPIClient` or the push feed.

## Workflow

Claude edits and pushes code from a cloud session. The owner then pulls the changes in Xcode (Source Control > Pull) and builds there. The owner does not use Terminal to update the repo, so do not ask them to run git or shell commands; commit and push to the working branch yourself.

- Xcode and the iOS simulator are not available in the cloud container, so changes cannot be built or run here. Never say the app builds or works unless that was verified. When finishing a change, state plainly that it is unbuilt and list what to check after pulling and building in Xcode.
- The project file `BallparkMatchups.xcodeproj` is committed; there is no `project.yml` in the repo. Avoid editing `project.pbxproj` by hand unless a change requires it (for example adding or removing a file), and say so when you do.
- Optional checks that can run in the cloud container if a Swift toolchain is present: `cd Tools/swift-verify && swift test` (the push-feed patch core; it symlinks `BallparkMatchups/API/JSONValue.swift`) and `Tools/diffpatch-verify` (see its README). Whether a toolchain exists there has not been verified.

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
