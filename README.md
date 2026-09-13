# Football

A macOS menu bar widget for watching NFL games as they happen. The menu bar shows a
football and how many games are live; clicking it opens a panel with every game's score,
who has the ball, where the ball is and how long is left in the quarter. Clicking a game
opens that game on its own, with its recent plays drawn on a minimal field map.

Built with SwiftUI and Liquid Glass for macOS 26.

## Build and install

```sh
Scripts/build_app.sh        # produces build/FootballWidget.app
Scripts/install.sh          # copies it to /Applications and launches it
```

No Xcode project — `swift build` and a shell script that assembles the bundle. The app
is ad-hoc signed, which is enough for local use and for notifications to be delivered.

Turn on **Launch at login** in Settings › General once it is in `/Applications`.

## The field map

The centrepiece is the ladder: one row per play, all sharing a single yard scale. Play
order reads top to bottom, field position reads left to right, and the drive always runs
towards the right-hand end zone.

```
NE ▌ 10   20   30   40   50   40   30 ▌ SEA
 ⚑                                        Drive start
 1     ◀████                              1st & 10   −10
 3     ████████▶                          2nd & 21   +19
 6          █████▶                        1st & 10   +12
17                    ◀▊                  3rd & 5    Intercepted
```

Gains run forward in the offense's colour, sacks and penalties run backwards in red, and
a turnover return is drawn in the defending team's colour. Clicking a row expands the
full play description, or the button in the drive header opens all of them at once. The
drive log underneath redraws the field for any earlier drive.

A finished drive ends with a banner saying how it ended and who got the ball —
`↩ TURNOVER ON DOWNS · SF ball`. Without it, a drive ending was signalled only by the
next play changing colour, which says nothing about what happened.

### Reading ESPN's play feed

Two things about the source data are worth knowing, because both look like bugs if you
draw the feed naively:

- **Frames flip mid-play.** Each `start`/`end` node reports `yardsToEndzone` against
  whichever end zone the team named in that node is attacking, and that team changes on
  kickoffs, punts and turnover returns. Those nodes are mirrored before being placed on
  the shared scale — without that, an interception returned four yards draws as a sweep
  across two-thirds of the field.
- **Clock events look like plays.** Timeouts, the two-minute warning and end-of-period
  markers report `start.yardsToEndzone == 0` with a real `end`, so they draw as
  full-width bars. They are filtered by play-type id, not by name — ESPN's casing is
  inconsistent ("Two-minute warning" vs "End of Half").

Both rules are pinned down by tests in `Tests/FootballCoreTests/FieldGeometryTests.swift`
against a recorded game.

## Fantasy

Connect one or more ESPN leagues in Settings › Fantasy and the widget learns which
players are yours and which are your opponent's. One ESPN sign-in covers every league
you are in, so adding a second needs only its league ID.

With more than one league connected, one is *active* — it is the one the matchup view
and the menu bar follow, chosen from the radio button in Settings or the menu in the
matchup view's title. Everything else pools across all of them: the badge on a game row
counts your starters from every league (each player once), and alerts fire for all of
them, with the league named in the banner.

- **Matchup view** — your starters against theirs with live points, reachable from the
  panel footer.
- **On the game list** — a green badge on each game showing how many of your starters
  are playing in it.
- **In the play map** — when a play scores for someone in your matchup, the row is
  tinted and carries a chip: `J. Chase +12.4`, green for yours and orange for your
  opponent's.
- **In game detail** — everyone from your matchup who is playing in that game.
- **Menu bar** — can show `78.2 – 71.5` while nothing is being played. It is one of the
  choices under Settings › General › *When nothing is live*, alongside the kickoff
  countdown; a live game always takes the space back.

### Connecting

Settings › Fantasy walks it in three presses:

1. **Copy command** puts a one-line snippet on your clipboard.
2. **Open ESPN** takes you to fantasy.espn.com. Sign in and open *your league's* page.
3. Open the browser console (**⌥⌘J** in Chrome, **⌥⌘C** in Safari), paste, press Return.
   It reads ESPN's cookies from that page and copies back a code beginning `FW1`.
   Paste that into the app and press Connect.

The code is base64 carrying the league id and both cookies, so one paste configures
everything — the league id comes from the page URL. The snippet talks to nothing but the
page it is already on.

The cookies are saved to `~/Library/Application Support/FootballWidget/credentials.json`,
created `0600` inside a `0700` directory. They were originally in the Keychain, which is
the textbook answer and the wrong one here: macOS ties a keychain item's ACL to the code
signature of the app that created it, and an ad-hoc signed app gets a new signature every
rebuild. Once it changes, every read raises the "enter your login keychain password"
dialog — and the poller reads twice every fifteen seconds during a live game. A file with
owner-only permissions is the same protection level as the app's own preferences, and it
never prompts.

If the console cannot read the cookies — some browser configurations mark `espn_s2`
HttpOnly — "Enter it by hand instead" takes the league URL and the two cookie values
directly, which you can read from developer tools under Storage (Safari) or Application
(Chrome) → Cookies → fantasy.espn.com.

Setup distinguishes the two failure modes: a 401 means the league is private and wants
cookies, a 404 means there is no league with that ID. Your own team is identified from
the SWID, so there is no team to pick from a list.

### How points get onto a play

ESPN's NFL play feed carries no per-player breakdown — plays have `teamParticipants`
but no `participants` array — so involvement is read out of the play text, which names
players as `S.Darnold`, `J.Smith-Njigba` and so on. Candidates are narrowed to rostered
players whose NFL team is in that game, so a surname competes against a handful of
names rather than the whole league.

Points are never recomputed here; ESPN stays the source of truth. When a player's
`appliedStatTotal` moves between polls, that change is banked against the most recent
play naming them. Two things follow from that, and are worth knowing:

- **Plays from before the widget first saw them have no chip.** ESPN reports running
  totals, not per-play points, so there is nothing to back-fill from. What has been
  worked out is saved to disk and reloaded, so a restart does not wipe the chips off
  a drive you are watching.
- **Starters only.** A bench player scores nothing for either side, and benching a
  quarterback — named in every dropback — would chip most of a drive.
- **Ambiguity is dropped rather than guessed.** If two rostered players on the same
  team share an initial and surname, neither is credited. Defensive and kicking points
  often have no naming play, so they show in the matchup view and in notifications but
  not on the field map.

Two joins make this work, and both were verified against live data rather than assumed:
fantasy player ids are the same as ESPN's NFL athlete ids, and fantasy `proTeamId` is
the same as the NFL team id.

## Alerts

Scoring plays, turnovers and red zone entries. Settings › Alerts chooses between all
games, favourite teams only, or off, and each type can be switched off individually.

Fantasy alerts fire for starters on either side of your matchup — every touchdown, plus
any play worth at least a configurable threshold (6 points by default), so a Sunday
brings a handful of banners rather than hundreds. Downward stat corrections update
totals but never interrupt. The notification is sized to fit a banner without
truncating:

```
Yours · Ja'Marr Chase +12.4
TD · 26.7 total · You 78.2 – 71.5
J.Burrow 14 yd pass to J.Chase for 14 yards, TOUCHDOWN.
```

Alerts are derived from the scoreboard — score deltas, `lastPlay` and `isRedZone` —
rather than from the play feed, so they work for every game on the slate rather than
only the one on screen. A game is never alerted on the first time it is seen, so
launching mid-afternoon does not replay the whole day.

## Refresh rate

Polling follows what is actually happening, with conditional requests so an unchanged
response costs a 304:

| State | Interval |
|---|---|
| No games today | 30 min |
| Games today, none live | 5 min (60 s inside 10 min of kickoff) |
| Live, panel closed | 20 s |
| Live, panel open | 10 s |
| A game's detail open or pinned | 5 s |

## Development

```sh
swift build                     # compile
swift test                      # 104 tests, no network needed
```

Two flags help when there is no football on:

```sh
# Replay a finished game as though it were live, one play every 0.3s.
build/FootballWidget.app/Contents/MacOS/FootballWidget --replay 0.3

# Show the panel in an ordinary window instead of the menu bar.
build/FootballWidget.app/Contents/MacOS/FootballWidget --preview --replay 0.5

# Render the views to PNGs offscreen and print the ladder as text, then quit.
build/FootballWidget.app/Contents/MacOS/FootballWidget --snapshot /tmp/shots

# Record your connected league as a test fixture, with member ids and names redacted.
build/FootballWidget.app/Contents/MacOS/FootballWidget --dump-fantasy Tests/FootballCoreTests/Fixtures/league.json
```

`--replay` pulls a real completed game from ESPN and reveals it play by play, which
exercises the live panel, the ladder filling in and all three alert types on a day with
no games.

### Layout

- `Sources/FootballCore` — wire types, domain model, field geometry, play attribution,
  alert rules. No UI, no networking, all of it tested.
- `Sources/FootballWidget` — the app: networking, polling, notifications, SwiftUI views.
- `Tests/FootballCoreTests` — runs against two recorded ESPN payloads in `Fixtures/`.

`Tests/FootballCoreTests/Fixtures/league.json` is a reconstruction of ESPN's league
shape, not a recording — no league credentials were available while the fantasy mapper
was written. `--dump-fantasy` replaces it with a real payload, at which point those
tests start running against reality rather than against an assumption.

## Data source

ESPN's public `site.api.espn.com` endpoints, plus `lm-api-reads.fantasy.espn.com` for
fantasy. No key, no account. They are undocumented,
so every field decodes as optional and array elements decode individually — one
malformed game cannot take down the rest of the slate. If ESPN reshapes something the
panel degrades to score and clock rather than going blank.
