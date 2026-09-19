# diffPatch algorithm verification

`BallparkMatchups/API/JSONValue.swift` applies RFC 6902 patches to a raw GUMBO
tree. That code cannot be exercised without a live game, and a patch bug is the
kind that shows a plausible-but-wrong stat rather than crashing — so the
algorithm is checked here against captured MLB traffic before it is trusted.

`algorithm-port.js` is a line-for-line port of the Swift control flow: same
navigation, same vivification rules, same points of failure. If the two ever
drift, this harness stops being evidence — keep them in step.

## Running

```sh
git clone --depth 1 https://github.com/AlecM33/mlb-gameday-bot ./reference
node run.js
```

## What it checks

- Both captured diff batches apply cleanly, and produce a result **byte-identical**
  to the reference implementation's.
- The reference project's own spec assertions (replace, sequential add, remove,
  copy, nested append) hold against this algorithm.
- RFC 6901 escaping: `~1` → `/`, `~0` → `~`, and keys containing a literal `.`
  survive. A slash-to-dot path split silently mangles all three.
- Absent intermediate containers are built on demand.
- A failed operation throws rather than writing a hole into the tree.

## Findings from the captured traffic

Measured across both fixture pairs (290 operations total: 236 `replace`,
25 `remove`, 22 `add`, 5 `copy`, 2 `move`):

- **All 34 array `add` operations are appends.** Zero mid-array inserts, zero
  index gaps — *when applied cumulatively and in order*. Measured against the
  pre-patch feed instead, several look like out-of-bounds writes, which is the
  trap: MLB emits runs of appends to the same array (thirteen consecutive
  `pitcherHotColdZones` adds) that are only in bounds once their predecessors
  have landed. Order of application is load-bearing.
- Because every array add is an append, RFC-correct insert semantics and
  assign-at-index semantics coincide on this data. The Swift implementation uses
  the spec's insert, which is also correct for the mid-array case should MLB
  ever emit one.
- `copy` operations point `from` at semantically unrelated locations
  (a play's `pitchIndex` sourced from a pitching stat). MLB's differ is
  value-oriented, not meaning-oriented. Standard `copy` semantics handle it;
  do not try to interpret `from`.

## Licensing boundary

[AlecM33/mlb-gameday-bot](https://github.com/AlecM33/mlb-gameday-bot) is
**GPL-3.0**. Nothing from it is copied into this repository — not code, not test
fixtures. It is cloned at run time into `reference/` (git-ignored) purely as an
oracle to compare against.

The Swift implementation is written from RFC 6902 and RFC 6901 plus observed API
behaviour. Endpoint URLs, the socket heartbeat string, and the push event's field
names are facts about MLB's service, not expression borrowed from that project.
Keep it that way: **do not paste code from the reference into `BallparkMatchups/`.**
