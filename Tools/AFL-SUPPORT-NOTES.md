# Arizona Fall League support — research notes

Everything below was verified against the live Stats API — the API survey on
2026-09-28, the opening-day lookups on 2026-10-03 — not inferred. AFL 2026
runs Oct 3 – Nov 14.

Line references are against `main` at `1fbb72b`.

## Short answer

The app does **not** show AFL games today. One gate blocks them: the
`sportId` list. Everything else already works.

| Gate | AFL status |
|---|---|
| `sportId=1,11,12,13,14` (`MLBAPIClient.swift:21,28`) | **blocks** — AFL is `sportId 17` |
| `gameTypes=R,F,D,L,W` | passes — AFL games are `gameType: "R"` |
| `validGames` (`MLBAPIClient.swift:213`) | passes, same reason |
| `venues.json` | Camelback Ranch (3809), Scottsdale Stadium (2532), Peoria Stadium (2530) all present with coordinates + `America/Phoenix` |
| Venue `sportId` | hardcoded to 1 in `VenueCache.swift:49`, not a gate |
| Team abbreviations | present (`SRR`, `SCO`) — score header fine |

## What the feed contains

AFL games carry **full GUMBO**, despite `gamedayType: "E"`. Verified on
gamePk 825622 (2025-10-15, Salt River at Scottsdale):

- `currentPlay.result` with `event`, `eventType`, `description`, `rbi`, scores
- `playEvents[].pitchData` with Statcast: `spinRate`, `spinDirection`,
  `breakAngle`, release `extension`, `zone`, plate coordinates, `pitchNumber`
- `metaData.logicalEvents` includes `countChange`, `count13`, `basesEmpty` —
  the same pitch-level events the push feed keys off
- `gameData.players` with `batSide`, `pitchHand`, strike-zone bounds

Identity is in the feed itself:

```json
"league": {"id": 119, "name": "Arizona Fall League"},
"sport":  {"id": 17,  "name": "Winter Leagues"}
```

## The real work: splits

This is what makes AFL support non-trivial.

`/people/{id}/stats?stats=statSplits&sitCodes=vr,vl&group=hitting` returns
**`"splits":[]`** for an AFL player — the endpoint defaults to MLB, and these
are prospects with no MLB service time.

Adding `sportId` + `season` works:

```
/people/700784/stats?stats=statSplits&sitCodes=vr,vl&group=hitting&sportId=12&season=2025
→ vs Right: 154 PA, .290/.351/.384
  vs Left:   64 PA, .155/.219/.241
  Corpus Christi Hooks · Texas League · sportId 12 (Double-A)
```

Sample sizes clear the existing thresholds (25 PA career / 15 PA season), so a
populated card is achievable.

**`sportId` does not accept a list.** `sportId=11,12,13,14` returns
`Invalid Request with value: 11,12,13,14`. So each player's level must be
known before the splits can be requested.

## Correction: minor-league stats are already handled

An earlier draft of these notes claimed MiLB splits were broken app-wide.
**That was wrong**, drawn from a stale checkout. `84dec37` threaded `sportId`
through every stats call, sourced from the game's own feed:

```swift
if let id = feed.gameData.teams.home.sport?.id { sportId = id }   // GameViewModel:302
```

For AAA/AA/High-A/Low-A that is exactly right — the game's league *is* the
player's league. AFL is the one case where they differ.

## Why AFL needs more than a sportId

For an AFL game, `gameData.teams.home.sport.id` is **17**. Splits at
`sportId=17` would be a handful of Fall League plate appearances, which the
25 PA career / 15 PA season thresholds reject. The card would come up empty.

What is wanted is the player's *own* league — Briggs McKenzie's 2026 High-A
season, not his two AFL innings.

## The lookup chain (verified live, 2026-10-03, opening day)

```
people/{id}?hydrate=currentTeam   →  currentTeam.id  432       (already fetched per batter/pitcher)
teams/432                          →  sport.id 13 (High-A)      (static; cache for the session)
people/{id}/stats?stats=statSplits&sitCodes=…&sportId=13&season=2026
```

Three findings from opening day, all confirmed against the live service:

- **`currentTeam` stays on the MiLB club during the AFL.** Briggs McKenzie
  (828987) reads `Rome Emperors` (id 432, `parentOrgId` 144) while actually
  pitching for the Glendale Desert Dogs. This was the one thing that could
  have killed the approach, and it held.

  > **Corrected 2026-10-07.** It holds for *some* players, not all. The
  > 10-06 game resolved a matchup to `13/12` — two real MiLB levels — but the
  > 10-06 late game read `17a/17a` on both sides, meaning `currentTeam` for
  > those players *was* the Fall League club. So the field is inconsistent
  > player to player, and any fix has to handle both. Whether it tracks an
  > active AFL roster assignment, or simply updates at different times for
  > different players, is not established.
- **`hydrate=currentTeam(sport)` does not work.** MLB silently ignores the
  nested hydrate and returns a payload identical to plain `currentTeam` — no
  error, just no `sport`. So the level cannot come free from the call the app
  already makes.
- **`teams/{id}` carries `sport`.** Rome Emperors → `{"id":13,"name":"High-A"}`.
  One extra call per distinct club, cacheable forever since teams do not change
  level mid-season, and only ever needed for the current batter and pitcher.

## Status: implemented and confirmed live

Built for iPhone and Mac with no errors, and verified against a live AFL game
on 2026-10-03 (Salt River at Glendale):

- AFL games list under the MiLB tab with an `AFL` badge
- The live card drives normally — batter, pitcher, situation, last play
- Splits resolve to the player's **own** league. Chase Harlan's card reads
  **"High-A career"**, `VS RIGHT .250/.356/.409 (104 PA)`,
  `TWO STRIKES .169/.254/.237 (67 PA)`, with 12 candidates filtered to 2 —
  the same behaviour as an MLB card. A label reading "AFL career" would mean
  the fallback had fired.
- The push feed works on AFL games too: socket connected, patches applying,
  `sv0 tc0 ob0`, no failures.

### Known cost

A player's first appearance needs `fetchPlayer` then `fetchTeam` to complete
before the splits request can be sent — two extra sequential round trips, AFL
only. Cards seen immediately after opening a game can render before the splits
land. Both caches hit thereafter. If the delay proves noticeable at a park, the
fix is to resolve the on-deck batter's league ahead of time rather than on
demand.

### Still thin by nature

Head-to-head will read "First meeting" for nearly everyone: two prospects who
have faced each other only in the Texas League have no shared-level history.
Correct, not broken.

## Shape of the work

- add `17` to the schedule and venue `sportId` lists (`MLBAPIClient.swift:21,28`)
- add a `SportLevel` case for 17 so the level badge renders
- add `fetchTeam(id:)` returning `sport.id`, plus a team→level cache
- at `GameViewModel.swift:302`, when the game's league is 17, resolve each
  player's own league rather than the game's; every other level keeps today's
  behaviour untouched

Expect BvP to read "First meeting" for nearly everyone — two prospects who have
met only in the Texas League have little head-to-head. Correct, not broken, but
it is what an AFL card will mostly show.

## If the splits cannot be made to work

The card degrades cleanly — `LiveCardView.swift:20` guards
`if !card.batterSplits.isEmpty` and `:24` guards `if let pitcherSplit`, so
missing splits render nothing rather than empty boxes. An AFL card would still
show score, situation, batter and pitcher with handedness, pitch count and last
play, with BvP reading "First meeting" for nearly everyone.

That is a reasonable experience for watching unidentifiable prospects, but it
is not what the App Store description promises. A three-line change (add `17`
to the two queries plus a `SportLevel` case in `AppModels.swift:6`) would ship
it — **not recommended without the splits**, since an app built on situational
stats that shows none invites one-star reviews from people who never learn why.

## The League b/p overlay row never worked (found 2026-10-06)

The row added to diagnose the silent fallback could essentially never fire,
which is why it is absent from every screenshot of the 2026-10-05 game. Two
faults, both mine:

1. It recorded only on a cache **miss**. `league(for:)` returns early on a
   cache hit and on an in-flight hit, so after the first lookup of a player
   nothing was written.
2. It compared `playerId` against `lastTickState?.batterId` — but
   `lastTickState` is not assigned until *after* the card is built, so during
   a lookup it still held the **previous** batter, and nil for the first of
   the game.

Fixed by splitting the cache logic into `resolvedLeague(for:)` and having
`league(for:)` record on every call against a side the caller passes in. The
three call sites all know which side they are asking about; `fetchSplits`
reads it off its `group` argument ("pitching" or "hitting").

**So no information about the fallback was gathered from that game.** The
question is still entirely open: when a Fall League player's splits come back
labelled "High-A career" over a 30 PA sample, is `league(for:)` returning 17
(the fallback) or a real level?
