# BallparkMatchups

Live batter-vs-pitcher matchup data for any MLB or MiLB game. Built for at-the-park use.

Free, no ads, no IAP. Uses the MLB Stats API (non-commercial individual use).

---

## Setup

### 1. Install XcodeGen

```bash
brew install xcodegen
```

### 2. Generate the Xcode project

```bash
cd "/Users/nick/Claude Code/BallparkMatchups"
xcodegen generate
```

This creates `BallparkMatchups.xcodeproj`. Open it in Xcode, set your Development Team in Signing & Capabilities, and build.

### 3. First run

The app bundles `Resources/venues.json` (168 venues, fetched 2026-05-12). It refreshes automatically every 30 days.

---

## Coverage

- MLB · AAA · AA · High-A · Low-A
- Regular season + playoffs (R, F, D, L, W)
- Excludes Spring Training, Exhibitions, All-Star, Complex/Rookie, DSL

---

## Architecture

```
AppViewModel          top-level state machine, session persistence
  └── GameViewModel   per-game polling loop, diff logic, split selection

MLBAPIClient          all network calls (actor, one in-flight request per game)
VenueCache            bundled + refreshed venue list, Haversine matching
LocationService       CLLocationManager wrapper
SplitPriorityEngine   §10.4 priority ranking + §10.5 info-gain filter

LiveFeedStream        experimental push path: Gameday socket + diffPatch
  ├── GamedaySocket   reconnecting websocket, heartbeat, dedupe
  └── JSONValue       raw JSON tree + RFC 6902 patch application
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

- In Progress: 5s
- Between innings: remainder of ~120s, then 5s so the first pitch isn't missed
- Pre-game < 15 min: 30s
- Pre-game > 15 min: 5 min
- Delay/Suspended: 60s
- Final/Postponed: stopped (the loop terminates)

---

## Push Feed (experimental, off by default)

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

Every failure path ends in a full refetch. Patches are applied to a copy and
committed only on success, so a mid-batch throw leaves the live tree untouched —
stale-but-correct beats partially-patched.

Polling is **not** switched off when this is on; it drops to 60s as a backstop. A
dropped socket event is invisible — there is no error to catch and nothing to
retry — so the loop stays as a net, and `diffTickState` discards the redundant
work for free.

**Status: unproven.** The path cannot be exercised outside a live game. The patch
algorithm is verified against captured MLB traffic (`Tools/diffpatch-verify`),
but the socket, the endpoints, and the failure handling have not been watched
through a real one. Enable it from the debug overlay and compare the byte
counters against the polling backstop before trusting it.

First thing to run on a Mac:

```sh
cd Tools/swift-verify && swift test      # typechecks the patch core under Swift 6
open BallparkMatchups.xcodeproj          # then build the app
```

`Tools/swift-verify` symlinks `BallparkMatchups/API/JSONValue.swift` rather than
copying it, so there is one source of truth and `swift test` compiles the same
code the app ships.

---

## Debug Overlay

Long-press (1.5s) anywhere on the game screen to toggle the debug overlay. Shows polling interval, last response time, request count, candidate splits vs. shown, last refresh kind.

When the push feed is enabled it also shows socket state, patches applied, full
refreshes, patch failures, and bytes over push vs. an estimate of what the same
updates would have cost as full polls. Tapping the "Push feed" row toggles the
flag; it takes effect when the game screen is reopened.

---

## Data Notes

- Venue timezone is used (not device timezone) to determine "today"
- BvP: full slash line at 6+ PA; raw line at 1-5 PA; "First meeting" at 0 PA
- Career splits: minimum 25 PA to display
- Season splits: minimum 15 PA to display
- Information-gain filter: drops splits within 30 OPS points of career OPS

---

## Out of Scope (v1)

Headshots, push notifications, favorites, Apple Watch, light mode, pitch-by-pitch detail, multiple simultaneous games.

---

## Open Questions

- PA thresholds may need tuning after real data
- OPS delta (30 pts) may need calibration
- Food rotator: expand to 20-30 lines
- Doubleheader edge cases need real-game testing
- Push feed needs a full live game before it can be considered for default-on
