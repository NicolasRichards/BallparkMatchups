#!/bin/sh
# Builds the simulator from the app's own sources and runs it (about 90 seconds).
set -e
cd "$(dirname "$0")"
APP=../../BallparkMatchups
OUT="${TMPDIR:-/tmp}/ballpark-game-sim"
swiftc -swift-version 6 -parse-as-library -o "$OUT" \
  "$APP"/Models/*.swift \
  "$APP"/API/APIModels.swift "$APP"/API/JSONValue.swift "$APP"/API/LiveFeedStream.swift \
  "$APP"/Services/SplitPriorityEngine.swift "$APP"/Services/APIDates.swift \
  "$APP"/ViewModels/GameViewModel.swift \
  FakeAPI.swift FakeSocket.swift Sim.swift
"$OUT"
