# Push feed — where this stands

Working notes for picking the Gameday push feed back up. The PR description
([#1](https://github.com/NicolasRichards/BallparkMatchups/pull/1)) carries the
design and the full findings; this is the operational state.

Last updated 2026-09-19, branch `claude/ballparkmatchups-baseball-stats-8bkxmp`.

## Status

Working end to end on a live game. Off by default.

The full chain runs: socket → frame decode → `diffPatch` → RFC 6902 apply →
re-decode → `diffTickState` → UI. Measured on LAD–SF, 9th inning: 6 patches,
0 failures, 0 unrecognised frames, `Last refresh: situational` confirming
patched data drove the card.

| | |
|---|---|
| Full GUMBO feed | 763 KB, growing through the game (698 KB ten minutes earlier) |
| Per push update | ~9 KB |
| Cumulative | 819 KB push vs 5,344 KB polling — 85% less |

## Picking it back up

```sh
git checkout claude/ballparkmatchups-baseball-stats-8bkxmp
cd Tools/swift-verify && swift test     # 16 tests, seconds, no Xcode needed
```

Run that before an Xcode build — it typechecks `JSONValue.swift` and
`GamedaySocket.swift` under Swift 6 language mode and fails fast.

To exercise the feature: long-press the game screen → tap the bordered
**PUSH FEED** box → back out to the game list → re-enter the game. The flag is
read once in `startPolling()`, so a running session will not pick it up.

## What has never executed

- `full_refresh`, and the whole-object-instead-of-a-diff response — both
  handled in code, neither has fired
- Pitcher changes, inning changes, mid-at-bat substitutions
- A long quiet period (the `URLSession` timeout fix is unverified)
- Reconnection after a genuine drop
- Backgrounding and foregrounding — the actual ballpark case
- Anything before the 9th inning; total sample is six patches

Next useful test is one ordinary game from the first pitch, watching
`Patch fails` and `Odd frames` stay at zero across innings and pitching
changes. Worth leaving off by default until it has had a game at a park on
stadium cell service, which is the environment it exists for.

## The one finding that mattered

Gameday sends `{"gamePk":"823898"}` — a quoted string — although MLB's own
typings call it a number. Synthesised `Codable` decoding threw and discarded
*every* frame, so the socket sat connected doing nothing with no error
anywhere. `GamedayPushEvent` now decodes field by field; only `updateId` can
fail a frame. `Tools/swift-verify` has the captured frame as a regression test.

The reference implementation is JavaScript and never type-checks it, which is
presumably why nobody noticed.

## Two harnesses, and why both

- `Tools/swift-verify` — `swift test`, runs the real Swift source (the files
  under `Sources/PatchCore` are **symlinks**, not copies). Authoritative.
- `Tools/diffpatch-verify` — `node run.js`, runs a JS port of the same
  algorithm against **captured MLB fixtures**, cross-checked byte-for-byte
  against a known-good implementation. Needed because those fixtures are
  GPL-3.0 and cannot be vendored into this repo; it clones them at run time
  into a git-ignored `reference/`. Keep that boundary: do not paste code from
  `reference/` into `BallparkMatchups/`.

If the two ever disagree, the JS port has drifted from the Swift — fix the
port, it exists to mirror it.

## Pre-existing bugs fixed in passing

Each is its own commit, cherry-pickable to `main` if this branch goes nowhere.

- `33c3377` — missing `import Combine` in two views; warned on every build
- `b51b671` — `DebugInfo.pollingInterval` was declared `= 12` and never
  assigned, so the overlay reported 12s no matter what `nextInterval()`
  returned. Live play has been 5s for as long as that code existed. Almost
  certainly the source of the README's stale "In Progress: 12s".

## Environment note

The session this was written in had no Swift toolchain and no route to one
(swift.org, GitHub release assets, Docker Hub and GHCR blob hosts all blocked
by network policy), and `statsapi.mlb.com` was unreachable. Everything was
verified either through the JS harness or by Nicolas building and running on
his Mac. Assume the same constraints unless proven otherwise — and never
report Swift changes from that environment as compiled.
