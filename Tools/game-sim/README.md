# game-sim

Runs the app's real `GameViewModel` and `LiveFeedStream` through scripted games,
so the live-game logic can be checked when there is no live game. Only three
things are stand-ins:

- `FakeAPI.swift`: an `MLBAPIClient` with the same methods, serving scripted
  feeds and canned stats, and failing on request (a server error, or no answer
  at all)
- `FakeSocket.swift`: a `GamedaySocket` the simulator can speak through as if it
  were MLB's, and a `FeatureFlags` it can switch
- `Sim.swift`: the scenarios

Everything else is compiled straight from `BallparkMatchups/`, so the code under
test is the code the app ships.

```sh
./run.sh        # about 90 seconds; exits non-zero if any check fails
```

It needs a Mac with the Swift toolchain. The checks are timed against the real
poll loop (5s between polls and so on), which is why it takes a while. On a very
busy machine a check can miss its window; run it again before believing a
failure.

## What it covers

Poll path, push off:

- a stats request that fails every time: the new batter's card still appears,
  with the stats that did load, and the request is retried 3 times (5s, 10s,
  20s apart) rather than on every update
- one dropped request: the card appears at once and is completed on the retry
- an out or runner change while the splits refetch is failing: the outs and
  runners still update
- two ordinary at-bats with nothing failing, including the exact number of
  requests each makes
- the phone locking in the middle of a refresh, then unlocking

Push path:

- the kill switch trips after three failed patches even with empty answers
  between them
- requests the network never answers do not trip it and cost no refetch
- polling restarts within seconds when push shuts itself off, and when the
  socket drops
- updates during a half-inning break do not restart the poll loop
- a late-inning break is not polled every 5s while the socket is healthy

Each of these failed against the code as it stood before the 2026-11-16 fixes
(17 failing checks), which is the evidence that the scenarios test what they
claim to.

## Keeping it working

- The fake `MLBAPIClient` must offer every method `GameViewModel` and
  `LiveFeedStream` call. A new call in either shows up here as a compile error.
- `run.sh` compiles `Models/*.swift` by wildcard, so a new model file is picked
  up automatically. A new file anywhere else that the view model depends on has
  to be added to the list in `run.sh`.
- Add a scenario when fixing a bug in the live-game logic: script the game that
  triggers it, check it fails before the fix and passes after.
