# BallparkMatchups

Live batter-vs-pitcher matchup data for any MLB, MiLB or Arizona Fall League game. Built for at-the-park use.

Free, no ads. The only in-app purchase is an optional tip jar. Uses the MLB Stats API (non-commercial individual use).

---

## Setup

The Xcode project is committed; there is nothing to generate. Open `BallparkMatchups.xcodeproj` in Xcode, set your Development Team in Signing & Capabilities, and build.

From the command line:

```bash
xcodebuild -project BallparkMatchups.xcodeproj -scheme BallparkMatchups \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

### First run

The app bundles `Resources/venues.json` (168 venues, fetched 2026-05-12). It refreshes automatically every 30 days.

---

## Coverage

- MLB · AAA · AA · High-A · Low-A · Arizona Fall League
- Regular season + playoffs (R, F, D, L, W)
- Excludes Spring Training, Exhibitions, All-Star, Complex/Rookie, DSL, and the other winter leagues that share the Fall League's sportId

---

## Architecture

```
AppViewModel          top-level state machine, session persistence
  └── GameViewModel   per-game polling loop, diff logic, split selection

MLBAPIClient          all network calls (actor)
VenueCache            bundled + refreshed venue list, Haversine matching
LocationService       CLLocationManager wrapper
SplitPriorityEngine   §10.4 priority ranking + §10.5 info-gain filter
PollSchedule          how long the poll loop waits, as a pure function
GameCompletion        whether the linescore says the game is over
StatsRetry            when to retry stats a card was built without

LiveFeedStream        push path: Gameday socket + diffPatch
  ├── GamedaySocket   reconnecting websocket, heartbeat, dedupe
  └── JSONValue       raw JSON tree + patch application (MLB's applier, not strict RFC 6902)
```

---

## Polling

Each poll fetches the **entire** GUMBO object from
`/api/v1.1/game/{gamePk}/feed/live` — there is no server-side diff on this path,
and the payload grows all game as plays accumulate. What keeps the cost down is
what happens *after* the fetch: `diffTickState` reduces the feed to a nine-field
tuple and classifies the change as `none` / `countOnly` / `situational` / `full`,
and only the last two trigger the expensive BvP and splits calls. Most polls
resolve to `none` and cost nothing further.

- In Progress: 5s, or 60s while the push feed is delivering patches
- Between innings: remainder of ~120s, then 5s so the first pitch isn't missed (20s throughout if the app opened mid-break)
- Break in the last scheduled inning or later: 5s when the push feed isn't healthy, since no socket is there to announce the end
- Game end announced or read off the linescore, status not yet final: 5s
- Pre-game < 15 min, or past the listed start: 30s
- Pre-game > 15 min: 5 min
- Start time TBD (game 2 of a doubleheader): 60s
- Delay/Suspended: 60s
- Game Over: 30s until "Final" (or W/L/SV decisions appear), for up to 15 min
- Final/Postponed/Cancelled: stopped (the loop terminates)

The schedule is `PollSchedule.interval`, a pure function with its own tests. When
the socket changes the card or drops in the middle of a sleep, the loop is
restarted if the card now wants checking sooner than that sleep would end
(`PollSchedule.shouldPollSooner`).

A stats request that fails does not hold the card back. The card is built with
what loaded, and the rest is retried up to three times, 5, 10 and 20 seconds
apart (`StatsRetry`).

---

## Push Feed (on by default)

An alternative to re-downloading the whole game every five seconds: subscribe to
the Gameday websocket and fetch only the changes.

```
wss://ws.statsapi.mlb.com/api/v1/game/push/subscribe/gameday/{gamePk}
https://ws.statsapi.mlb.com/api/v1.1/game/{gamePk}/feed/live/diffPatch
    ?language=en&startTimecode={ours}&pushUpdateId={theirs}
```

The socket is a doorbell, not a data feed — it carries an `updateId` and little
else. The change set is fetched separately, as an array of RFC 6902 operations,
and applied to a locally held copy of the game object.

Three things make this harder than it looks:

1. **`startTimecode` is our timestamp, not theirs.** The server needs to know
   where the client is, so it is `metaData.timeStamp` of the copy already held —
   updated after every successful patch.
2. **The response is not always a patch.** Gameday sometimes answers with a whole
   game object, and sometimes sends `changeEvent.type == "full_refresh"` telling
   the client to discard its copy. Both must be handled.
3. **Patches apply to the raw tree, not the typed model.** Operation paths reach
   into fields `LiveFeedResponse` never decodes. Patching a decoded model would
   corrupt it, so `JSONValue` holds the full tree and `LiveFeedResponse` is
   re-derived after each change.

Every failure that could leave the copy wrong ends in a full refetch. Patches are
applied to a copy and committed only on success, so a mid-batch throw leaves the
live tree untouched — stale-but-correct beats partially-patched. A request that
gets no answer at all (no signal, a timeout) changes nothing and is not
refetched: the next update's diff starts from the copy already held, and covers
it.

Three patch failures in a row, with no patch applied in between, shut the push
path off for the session and hand the card back to 5s polling. Empty answers and
unanswered requests do not count either way.

Polling is **not** switched off when this is on; it drops to 60s as a backstop. A
dropped socket event is invisible — there is no error to catch and nothing to
retry — so the loop stays as a net, and `diffTickState` discards the redundant
work for free. If the socket drops or the push path shuts itself off, the loop
is restarted at once rather than left to finish a 60s sleep.

**Status: on by default** since 2026-10-08, in every build. Complete games on a
phone, cell-only, measured 80–89% fewer bytes than polling the same games;
`Tools/PUSH-FEED-STATUS.md` has the numbers and the history. A Debug build can
switch it off from the debug overlay to compare against polling alone.

The path cannot be exercised outside a live game, so it has harnesses that need
none. First things to run on a Mac:

```sh
cd Tools/swift-verify && swift test      # patch core, poll schedule, retry rules, under Swift 6
Tools/game-sim/run.sh                    # the real view model and stream against scripted games, ~90s
open BallparkMatchups.xcodeproj          # then build the app
```

`Tools/swift-verify` symlinks its sources from `BallparkMatchups/` rather than
copying them, so there is one source of truth and `swift test` compiles the same
code the app ships. `Tools/game-sim` compiles them in place, with stand-ins for
the network client and the socket only. `Tools/diffpatch-verify` checks the patch
algorithm against captured MLB traffic.

---

## Debug Overlay

In a Debug build (one run from Xcode), long-press (1.5s) anywhere on the game screen to toggle the debug overlay. Archived builds have no overlay. Shows polling interval, last response time, request count, candidate splits vs. shown, last refresh kind.

When the push feed is enabled it also shows socket state, patches applied, full
refreshes, patch failures, requests that got no answer, and bytes over push vs.
an estimate of what the same updates would have cost as full polls. Tapping the
"Push feed" box toggles the flag; it takes effect when the game screen is
reopened.

---

## Data Notes

- "Today" rolls over at 3 a.m. Eastern for every venue, so late West Coast games stay listed after local midnight (not the venue's or the device's time zone)
- BvP: full slash line at 6+ PA; raw line at 1-5 PA. Intended: "First meeting" at 0 PA. At present the section is hidden instead, because a 0 PA line is dropped before it reaches the card
- Career splits: minimum 25 PA to display
- Season splits: minimum 15 PA to display
- Fall League splits: minimum 10 PA, season and career alike
- Information-gain filter: drops splits within 30 OPS points of the batter's overall OPS for the same scope (career or season)

---

## Out of Scope (v1)

Headshots, push notifications, favorites, Apple Watch, light mode, pitch-by-pitch detail, multiple simultaneous games.

---

## Open Questions

- PA thresholds may need tuning after real data
- OPS delta (30 pts) may need calibration
- Food rotator: expand to 20-30 lines
- Doubleheader edge cases need real-game testing
- The 2026-11-16 review fixes (push shut-off, kill-switch counting, stats retries, TBD starts) are covered by tests and `Tools/game-sim`, but have not yet run on a live game
