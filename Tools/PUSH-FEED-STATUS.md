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

## Full-game AFL measurement, 2026-10-04

One nine-inning Fall League game, start to finish, on an iPhone with the
screen awake the whole time, cell-only (no Wi-Fi), on battery for most of it.

| | |
|---|---|
| Patches applied | 439 |
| Full refreshes | 41 |
| Patch failures | 5 |
| Server-requested refresh / timecode / whole-object | `sv 35`, `tc 0`, `ob 36` |
| Deferred and retried | 4 succeeded, 3 dropped |
| Push bytes | 45,681 KB |
| Poll estimate for the same game | 384,192 KB |
| **Saved** | **88%** |

`sv` and `ob` are MLB asking for a full copy or answering with whole objects.
Together they are about two-thirds of what the push path still costs, and
neither is avoidable from the client — that is simply what the server sends.

## The end-of-game stall

Reported three games running: the last out lands and the card stops updating.
It never shows the third out and never shows the final — back out to the game
list and the game reads as ended; go back in and the card reads as ended too.
Waiting long enough also fixed it, which is the signature of an interval that
is too long rather than a feed that is wrong.

Three separate paths led to the same stall:

1. `LiveFeedStream` yields `.gameFinished` after taking one last full copy,
   and `GameViewModel` discarded it (`case .gameFinished: break`). MLB's REST
   feed still reads "In Progress" for a few seconds past the final out, so
   that last copy is usually *not* the final one — and by then the socket has
   closed, leaving the poll loop as the only thing that can notice.
2. With the socket counted healthy, `.live` backed the poll loop off to 60s.
3. The last out of the ninth looks exactly like any other half-inning break,
   so `.betweenInnings` settled onto its two-minute timer waiting for an
   inning that was never coming.

Fixed by latching a `gameEndAnnounced` flag when the socket says so, tearing
the socket down, restarting the poll loop immediately (`beginPollLoop()`, split
out of `startPolling()` so the socket is left alone), and treating the last
scheduled inning's break as "keep checking" even with no socket at all.

`scheduledInnings` now comes from `liveData.linescore.scheduledInnings` rather
than being hardcoded to 9, so a doubleheader's seven-inning game ends at the
seventh. The field's presence and position were confirmed from captured MLB
feeds; a non-9 value was **not** verifiable from that session, as
`statsapi.mlb.com` was blocked. The fallback is 9, so the worst case is the
behaviour that shipped before.

`PollSchedule.interval` was lifted out of `GameViewModel` for this, purely so
the decision is testable without a live game — `PollScheduleTests` covers all
three paths above plus every interval that must not have changed.

## The dropped operations, 2026-10-05

A second full Fall League game, cell-only, screen awake. The end-of-game fix
held — `FINAL` appeared promptly on the last out, with the loop at 5s and the
socket down. But the overlay ended on `Deferred: ok1 drop51`, with the last
failure reading:

    dropped add /liveData/plays/allPlays/82/playEvents/8/pitchData/breaks/spinDirection

Earlier screenshots in the same game showed `add /metaData/logicalEvents/4`,
`replace /metaData/logicalEvents/1` and `add /metaData/logicalEvents/3`.

### Cause

Our applier enforced RFC 6902 bounds. **MLB's diffPatch stream is not RFC
6902.** The reference implementation's entire leaf write is:

```js
root[currentAccessor] = value;     // for BOTH add and replace
```

Plain assignment. In JavaScript `arr[5] = v` on a two-element array simply
grows it, leaving holes that stringify as `null`. Its traversal does the same:
`if (root[accessor] === undefined) root[accessor] = {}` — at any index, however
far past the end. The author says so outright in the module comment: *"the JSON
paths diffPatch give me are not guaranteed to point to defined values."*

So the server has always been written against assignment semantics. Refusing
the write left our array one element short of the server's — and then **every
later operation indexed into that array failed too**. That is the cascade: one
short array, 51 dropped operations.

### Fix

`JSONValue.grow` pads with nulls up to the index, in both the leaf write and
the path traversal, so an out-of-range write grows the array instead of
throwing. Byte-for-byte identical to the reference on every case, including
the exact `logicalEvents/4` shape seen live — `Tools/diffpatch-verify` now
runs each one through **both** implementations and compares.

Three consequences worth knowing:

- An in-bounds `add` is still a true insert (RFC 6902). This is the one place
  we deliberately differ from the reference's plain assignment, and nothing in
  the captured traffic exercises it.
- The two decoded arrays in the live feed — `allPlays` and `boxscore…pitchers`
  — now hold **optional** elements. A null hole would otherwise throw during
  decode and fail the whole feed, which would have been worse than the drop.
- Padding is capped at 10,000. The index arrives off the network; a corrupt
  frame naming index 2,000,000,000 must not be met by allocating until the app
  dies. Beyond the cap it throws, and the caller refetches.

Holes self-heal: `descend` already replaces a null placeholder with a real
container when a later operation writes into that slot.

### Not fixed, deliberately

`isWorthRetrying` still defers `arrayIndexOutOfBounds`. Growth should mean it
never fires, but a deferred-then-dropped operation is cheap and a hard failure
costs a full refetch and counts toward the kill switch. The deferral stays as
a net rather than being tightened on the strength of an untested prediction.

## Third full game, 2026-10-06 — the growth fix measured

Salt River 7, Surprise 2. Start to finish on an iPhone, cell-only.

| | before (10-05) | after (10-06) |
|---|---|---|
| Deferred, dropped | **51** | **4** |
| Patch fails | 0 | 1 |
| Patched | 292 | 396 |
| Full refreshes | 23 | 32 |
| Push KB vs poll estimate | 34,309 / 285,215 | 36,464 / 325,723 |
| Saved | 88% | **89%** |

The cascade is gone. What remains is four dropped operations whose paths are
still unknown — a hard failure overwrote the record, which is now fixed by
keeping `lastDroppedOperation` separate from `lastFailedOperation`.

### The one hard failure

    remove /liveData/plays/currentPlay/result/rbi
    No value at /liveData/plays/currentPlay/result/rbi

Same class as the array bounds, opposite operation. The reference's remove is
`delete root[key]`, a no-op in JavaScript when the key is absent — and our own
*array* remove was already a no-op, with the comment "removing an element that
is not there has already been achieved". Only the object branch threw, costing
a full refetch to reach a state we were already in. Now a no-op, cross-checked
against the reference on four shapes.

## The Fall League fallback: confirmed, and ambiguous

The repaired `League b/p` row populated all game:

| time | b/p | |
|---|---|---|
| 5:00 | 17/12 | batter Fall League, pitcher AA |
| 5:11 | 13/12 | batter High-A, pitcher AA — both resolved |
| 6:05 | 17/14 | batter Fall League, pitcher Low-A |
| 6:44 | 17/17 | both Fall League |

So 17 appears often, and 13/12 proves the lookup *can* resolve a real level.
But a bare 17 is ambiguous and the two readings need opposite fixes:

- **The lookup failed** and fell back to the game's own league (17). Fix the
  lookup.
- **The lookup succeeded** and the player's current club genuinely *is* a Fall
  League team. Then the request is correctly scoped — to a sample of 30 PA,
  which is useless. Fix would be to climb to the player's parent organisation
  instead.

`LeagueOrigin` now distinguishes them with a suffix: `17a` the club really is
a Fall League team, `17p` no current team on the player, `17t` the team
carried no sport, bare number resolved normally. One more game settles it.
