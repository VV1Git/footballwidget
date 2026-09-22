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
- **Chance to win** — a bar under the score, split green (yours) and orange (theirs),
  with each side's projected total. The footer shows your percentage next to the score.
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

One more thing about `appliedStatTotal`: it is not scoped to a week. ESPN leaves the
previous week's total sitting in it until the new week's first game kicks off, so
between Monday night and Thursday it reports a finished week's points — against the new
week's opponent, and summed over the new week's lineup, which makes a score belonging to
neither week. Points are therefore read from the per-period stat line, which does reset;
no line for the period means nothing scored yet. A payload recorded mid-Sunday settles
that this costs no liveness: every one of its players' period lines matched
`appliedStatTotal` to the cent.

Two joins make this work, and both were verified against live data rather than assumed:
fantasy player ids are the same as ESPN's NFL athlete ids, and fantasy `proTeamId` is
the same as the NFL team id.

### Where the win probability comes from

ESPN computes it. The `mMatchupScore` view the widget already requests carries
`winProbability` on both sides of the matchup in progress, next to
`totalProjectedPointsLive`. These are the "Chance to Win" and "Proj Total" figures in
ESPN's FantasyCast, and they matched when checked side by side during a live week. The
widget shows ESPN's number unchanged. Near the ends it reads ">99%" or "<1%" while any
starter still has a game to play, because ESPN rounds to two decimals and would
otherwise show 100% with a game left.

Two cases don't use ESPN's number:

- **Nothing left to play.** Once ESPN declares a winner, or every starter's game on the
  NFL scoreboard is final, it is 100%, 0%, or 50% for an exact tie. ESPN only declares
  a winner once it processes the week, so the widget doesn't wait for that.
- **ESPN sends no number.** A finished season's schedule has none, for example. The
  widget then estimates one from each starter's weekly projection (`statSourceId` 1 for
  this scoring period, never the season line beside it). Each side's expected final is
  its points plus the projection still to come, scaled by how much of each game is left.
  The chance of winning is a normal CDF of the expected margin, with a variance of 16
  points² per remaining projected point. That figure was fitted to ESPN's live numbers
  and lands within a few percentage points of them. The bar is labelled *(est.)* in this
  case. If a starter still to play has no projection, the bar is hidden rather than
  showing a guess. The model lives in `Sources/FootballCore/WinProbability.swift`.

## Alerts

Scoring plays, turnovers and red zone entries. Settings › Alerts chooses between all
games, favourite teams only, or off, and each type can be switched off individually.

A banner shows one line of title and one of subtitle, so those carry the key facts —
who scored, who took the ball away and whose ball it is now — and the body is only
used when it adds something:

```
TD DET · A. St. Brown 19-yd catch          INT CHI · M. Muhammad picks off B. Young
DET 20–0 NO · Q3 8:54                      CHI ball at CHI 38 · CHI 31–24 CAR · Q2 0:05
From J. Goff

T. Shough fumbles · DET recovers           Turnover on downs · PIT ball
DET ball at NO 25 · DET 14–0 NO · Q3 9:54  PIT ball at MIN 32 · PIT 24–21 MIN · Q4 0:14
Strip-sack by R. McCreary                  4th & 17 · C. Wentz incomplete to J. Addison
```

The names come from ESPN's play text (`PlaySummary`), which is prose like `(Shotgun)
J.Goff pass deep middle to A.St. Brown for 19 yards, TOUCHDOWN.`. The parser only fills
in what it recognises, and the text is only used when it describes a score of the size
that just landed; otherwise the banner falls back to `TD DET`. A wrong name is worse than
none. A few things the rules deliberately do:

- **The extra point is not its own banner.** Live, the score moves +6 with the touchdown
  and +1 a poll later; the lone point is folded into the touchdown already announced.
- **A pick-six is one banner**, `TD JAX · D. Lloyd 99-yd pick-six`, not a turnover and
  a score.
- **Turnovers are read from the text as well as ESPN's flag**, which misses strip-sacks,
  muffed punts and kick-return fumbles, and counts missed field goals — those are called
  `ATL missed FG · N. Folk 45 yd` instead.
- **Plays under review wait for the ruling**, and plays wiped out by a flag never alert.
- **The red zone needs a team in possession.** ESPN reports the ball inside the 20 with
  no possession while a try or field goal is set up, which used to add a red zone banner
  to every score.

Fantasy alerts fire for starters on either side of your matchup — every touchdown, plus
any play worth at least a configurable threshold (6 points by default), so a Sunday
brings a handful of banners rather than hundreds. Downward stat corrections update
totals but never interrupt. The body is the play from the player's side:

```
Yours · Ja'Marr Chase +12.4
TD · 26.7 total · You 78.2 – 71.5
14-yd catch from J. Burrow
```

Alerts are derived from the scoreboard — score deltas, `lastPlay` and `isRedZone` —
rather than from the play feed, so they work for every game on the slate rather than
only the one on screen. A game is never alerted on the first time it is seen, so
launching mid-afternoon does not replay the whole day.

## Refresh rate

Polling follows what is actually happening:

| State | Interval |
|---|---|
| No games today | 30 min |
| Next kickoff more than 6 h off | 30 min |
| Games today, none live | 5 min (60 s inside 10 min of kickoff) |
| Live, panel closed | 20 s |
| Live, panel open | 10 s |
| A game's detail open or pinned | 5 s |

The six-hour row exists because the slate is not always today's. Once a week has been
played out the panel is showing the next one (below), whose first kickoff can be two
days away — and nothing about a Thursday game moves on a Tuesday.

Opening or closing the panel reschedules the next poll against the new interval rather
than forcing one, so a quick look does not cost a round of fetches.

The play feed is the heavy request, around half a megabyte per game. The game on screen
gets it at the rate above. A game that is only followed because someone in your fantasy
matchup is playing in it gets it when the scoreboard reports a play that its feed does
not have yet, and otherwise once a minute — the feed only needs the newest play for
points to be pinned on it.

ESPN sends no `ETag` or `Last-Modified`, so a conditional request never comes back 304.
Instead a body that is byte-for-byte the previous one for that URL — common, since the
CDN caches for a few seconds — is recognised by its fingerprint and skipped before it is
decoded.

## Which week the scoreboard answers for

ESPN's NFL week is not the calendar week and does not end when the football does. Each
week owns a window running Wednesday 07:00Z to the following Wednesday 06:59Z, and
`/scoreboard` with no parameters answers for whichever window contains now. So from the
final whistle on Monday night until Wednesday morning UTC — a little over a day, every
week of the season — the default scoreboard is a complete set of finals and the coming
week is nowhere in it. The panel had no upcoming games and the menu bar had no kickoff
to count down to.

Once every game in the week ESPN handed over is final, the widget asks for the next one
by name. Which week that is comes from the calendar ESPN ships in the same response
rather than from adding one to the week number, because there is no week 19: the
postseason is a separate season type whose weeks number from one again, and the
preseason runs into the regular season the same way. `ScoreboardCalendar` does that
lookup and the boundaries are pinned by tests against a recorded calendar.

## Development

```sh
swift build                     # compile
swift test                      # 225 tests, no network needed
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
