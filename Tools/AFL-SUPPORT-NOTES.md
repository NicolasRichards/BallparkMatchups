# Arizona Fall League support — research notes

Everything below was verified against the live Stats API on 2026-09-28, not
inferred. AFL 2026 runs Oct 3 – Nov 14.

## Short answer

The app does **not** show AFL games today. One gate blocks them: the
`sportId` list. Everything else already works.

| Gate | AFL status |
|---|---|
| `sportId=1,11,12,13,14` (`MLBAPIClient.swift:19,26`) | **blocks** — AFL is `sportId 17` |
| `gameTypes=R,F,D,L,W` | passes — AFL games are `gameType: "R"` |
| `validGames` (`MLBAPIClient.swift:185`) | passes, same reason |
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

## The cheap path, and the risk

`fetchPlayer` (`MLBAPIClient.swift:109`) already calls
`/people/{id}?hydrate=currentTeam` for every batter and pitcher. If that
response carries `currentTeam.sport.id`, the level comes for free — add a
`sport` field to `PlayerResponse.PersonDetail.TeamRef`
(`APIModels.swift:351`, currently only `id`/`name`/`abbreviation`) and thread
it into `fetchSplits` and `fetchBvP`.

**Unresolved until Oct 3:** whether `currentTeam` still reports the player's
MiLB club once the AFL is underway, or flips to their AFL club at
`sport.id 17`. If it flips, every player needs a separate level-discovery
call — roughly doubling the requests behind each matchup card.

### Test on day one

```
https://statsapi.mlb.com/api/v1/people/{batterId}?hydrate=currentTeam
```

Take `batterId` from a live AFL game's `currentPlay.matchup.batter.id`.

- `sport.id` = 11/12/13/14 → cheap path, roughly an hour of work
- `sport.id` = 17 → needs a level-discovery mechanism; decide whether the
  extra call per player is worth it

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
