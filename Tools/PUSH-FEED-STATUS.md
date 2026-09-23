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

Two full games measured, plus shorter sessions:

| | MIL–BAL (pre-fix) | MIN–SF (post-fix) |
|---|---|---|
| Patched / Full refresh / fails | 63 / 18 / 5 | 117 / 27 / **3** |
| Refresh why | sv12 tc0 ob10 | sv23 tc0 ob15 |
| Push vs polling | 18.3 / 54.2 MB (**66%**) | 30.8 / 108.2 MB (**71.5%**) |

`Full refresh` reconciles exactly both times: 1 seed + `sv` + patch failures.
`tc0` across both games — the timecode handling has never failed.

Essentially the entire push cost is full-size payloads: refreshes plus
whole-object responses come to roughly the measured total, so the 100-odd
genuine diffs are close to free. **`sv` and `ob` are MLB's behaviour and set
the floor** — a perfect client cannot get below them.

Earlier shorter runs:

| | 9th inn (LAD–SF) | 2nd inn (BOS–TB) | 3rd inn (BOS–TB) |
|---|---|---|---|
| Full feed | 763 KB | ~295 KB | 335 KB |
| Patched / Full refresh | 6 / 1 | 4 / 4 | 9 / **1** |
| Per update | ~9 KB | — | ~10 KB |
| Push vs polling | 819 / 5,344 (**85%**) | 1,240 / 2,358 (47%) | 429 / 3,351 (**87%**) |

The middle run's 4:4 ratio was an artifact of leaving and re-entering the
game: each re-entry builds a fresh `LiveFeedStream` and pays a new seed,
incrementing `Full refresh` without touching `sv`/`tc`/`ob`. Within a single
sustained session `Full refresh` stays at **1**.

So a patch costs ~10 KB against a 335 KB feed — roughly **33× cheaper per
update**, 87% cumulative and improving as the seed amortises. `Patch ops`
ran ~78 operations per update, confirming these are genuine small diffs.

Still unmeasured: a complete game from the first pitch, where the feed grows
past 700 KB and the ratio should improve further.

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

## Kill switch

Three **consecutive** patch failures shut the push path down for the session:
socket closes, stream reports `.disabled`, card returns to 5s polling. A
success resets the count. Seed failures are not counted — ordinary network
trouble, and polling would be failing too. Session-scoped, so the stored flag
survives and the next game tries again. The overlay shows a red
`PUSH DISABLED —` line with the reason.

Rationale: a persistently failing push path is *worse* than none, because
every failure costs a full refetch while the backstop poll still runs. An
early reading showed exactly that — 586 KB spent against 584 KB of polling.

## Known cost: foregrounding fetches twice

`handleForeground()` calls `startPolling()`, which immediately polls (one full
feed) **and** starts a new `LiveFeedStream` that seeds (another full feed).
Polling alone would cost one. So each unlock is roughly 2× the feed size.

Visible as `Full refresh` and `Request count` both incrementing together on
every foreground. Ten unlocks over a game is ~7 MB on cell, which could swamp
the savings for a frequent pocket-checker.

Not fixed: the poll fetches the typed model and the stream needs the raw
tree, so they are genuinely two different calls. Measure before deciding
whether to restructure.

## Soak test — what to record

Testing on a phone, cell service only, locking mid-game. Worth noting:

- Does `Socket` recover after iOS suspends the app? (`handleForeground`
  rebuilds it, never verified)
- Does the reconnect backoff behave when cell drops between innings?
- `Full refresh` vs `Request count` per unlock — the double-fetch above
- Whether the kill switch ever trips, and what `Last error` said
- Memory over a full game: the raw tree is held alongside the decoded model

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
