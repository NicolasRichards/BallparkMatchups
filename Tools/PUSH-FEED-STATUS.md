# Push feed — where this stands

Working notes for the Gameday push feed. The PR description
([#1](https://github.com/NicolasRichards/BallparkMatchups/pull/1)) has the
design; this is operational state and, below, how to read the results without
needing to ask anyone.

Branch `claude/ballparkmatchups-baseball-stats-8bkxmp`, head `14dcb6c`.
Last updated 2026-09-19.

## Status

Works end to end on live games. Off by default. The full chain runs: socket →
frame decode → `diffPatch` → RFC 6902 apply → re-decode → `diffTickState` → UI.

Two runs so far, and **they disagree about how much this saves**:

| | 9th inning (LAD–SF) | 2nd inning (BOS–TB) |
|---|---|---|
| Full feed | 763 KB | ~295 KB |
| Patched / Full refresh | 6 / 1 | 4 / 4 |
| Push vs polling | 819 vs 5,344 KB (**85% less**) | 1,240 vs 2,358 KB (**47% less**) |

One early reading was worse than break-even: 586 KB push against 584 KB
polling. The difference is `Full refresh` climbing at roughly the same rate as
`Patched` in early innings. Each refetch costs a whole feed, so a 1:1 ratio
wipes out the saving. **The real full-game number is unknown** — 85% was the
easiest possible case.

## Picking it back up

```sh
git checkout claude/ballparkmatchups-baseball-stats-8bkxmp
cd Tools/swift-verify && swift test     # 16 tests, seconds, no Xcode needed
```

Run that before an Xcode build — it typechecks `JSONValue.swift` and
`GamedaySocket.swift` under Swift 6 and fails fast.

To exercise it: long-press the game screen → tap the bordered **PUSH FEED**
box → back out to the game list → re-enter. The flag is read once in
`startPolling()`, so a running session will not pick it up.

## Reading the overlay — what to do about what you see

`Refresh why` shows `sv<n> tc<n> ob<n>`. These are the three reasons a full
refetch happened, and they need different responses:

| Reading | Means | What to do |
|---|---|---|
| `sv` climbing | Gameday genuinely asks for full refreshes this often | Nothing to fix. The saving is just smaller in early innings; report the honest number. |
| `tc` climbing | **Bug.** The tree lost `metaData.timeStamp` after an update, so the next request could not be built | Fix `LiveFeedStream.currentTimecode` / whatever is dropping it. This is the one worth chasing. |
| `ob` climbing | `diffPatch` answered with whole game objects instead of change sets | Not fixable client-side. Caps how good this can ever get. |

`Patch ops` shows total RFC 6902 operations applied. Tens per update means
genuine diffs are tiny and refetches are the entire cost. Thousands means MLB
is sending near-complete rewrites and the premise is weaker than it looked.

Other counters: `Patch fails` and `Odd frames` should both stay **0**; if
either climbs, `Last error` or the orange raw-frame text says why. `Socket`
should read `connected`; when down, a yellow line gives the close code.
`Poll interval` should sit at 60s while patches flow and 5s otherwise.

## Decision

Do not merge on a clean build. Merge on a full game's counters, and keep it
off by default until it has run at a park on stadium cell service — the
environment it exists for, and the one least like a simulator on a Mac.

If `ob` turns out to dominate, the honest conclusion may be that this is not
worth shipping. That is a legitimate outcome; the polling path already works.

## Not yet exercised

- Backgrounding and foregrounding at a real game
- Reconnection after a genuine drop
- A long quiet period (the `URLSession` timeout fix is unverified)
- A complete game from the first pitch

## The finding that mattered

Gameday sends `{"gamePk":"823898"}` — a quoted string — although MLB's own
typings call it a number. Synthesised `Codable` decoding threw and discarded
*every* frame, so the socket sat connected doing nothing, with no error
anywhere. `GamedayPushEvent` now decodes field by field; only `updateId` can
fail a frame. `Tools/swift-verify` has the captured frame as a regression test.

The reference implementation is JavaScript and never type-checks it, which is
presumably why nobody noticed.

## Two harnesses, and why both

- `Tools/swift-verify` — `swift test`, runs the real Swift source (files under
  `Sources/PatchCore` are **symlinks**, not copies). Authoritative.
- `Tools/diffpatch-verify` — `node run.js`, runs a JS port of the same
  algorithm against **captured MLB fixtures**, cross-checked byte-for-byte
  against a known-good implementation. Needed because those fixtures are
  GPL-3.0 and cannot be vendored; it clones them at run time into a
  git-ignored `reference/`. Do not paste code from `reference/` into
  `BallparkMatchups/`.

If the two disagree, the JS port has drifted — fix the port, it exists to
mirror the Swift.

## Pre-existing bugs fixed in passing

Each is its own commit, cherry-pickable to `main` if this branch goes nowhere.

- `33c3377` — missing `import Combine` in two views; warned on every build
- `b51b671` — `DebugInfo.pollingInterval` was declared `= 12` and never
  assigned, so the overlay reported 12s whatever `nextInterval()` returned.
  Live play has been 5s for as long as that code existed. Almost certainly the
  source of the README's stale "In Progress: 12s".

## Environment note

The session this was written in had no Swift toolchain and no route to one
(swift.org, GitHub release assets, Docker Hub and GHCR blob hosts all blocked
by network policy), and `statsapi.mlb.com` was unreachable. Everything was
verified either through the JS harness or by Nicolas building and running on
his Mac. Assume the same constraints unless proven otherwise — and never
report Swift changes from that environment as compiled.
