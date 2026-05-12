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
```

---

## Polling

- In Progress: 12s (GUMBO diff via timecode — ~5-10KB per poll)
- Between innings: 15s
- Pre-game < 15 min: 30s
- Pre-game > 15 min: 5 min
- Delay/Suspended: 60s
- Final/Postponed: stopped

---

## Debug Overlay

Long-press (1.5s) anywhere on the game screen to toggle the debug overlay. Shows polling interval, last response time, request count, candidate splits vs. shown, last refresh kind.

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
