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

A finished drive ends with a banner saying how it ended and, when the ball changed
hands, who got it — `↩ TURNOVER ON DOWNS · SF ball`. Without it, a drive ending was
signalled only by the next play changing colour, which says nothing about what happened.
A score is followed by a kickoff and the end of a half by nobody, so those banners name
no one; a pick-six or a safety is shown as the other side's points, not a star.

The label column says what a change of hands was — `Punt`, `Intercepted`, `Pick-six`,
`Punt blocked`, `FG missed` — read from the play text first and ESPN's play type second.
`On downs` is kept for an ordinary snap that came up short on fourth down. A try ESPN
posts as a play of its own is labelled `XP` or `2-pt`, not as a second touchdown, and a
kickoff returned all the way is drawn as the drive rather than a marker in the end zone.

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
  opponent's. Every play of the game gets its chips, including those from before the
  app was opened.
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

Each play is scored on its own, from its text, with your league's own scoring table, the
moment the play feed carries it. ESPN's fantasy API only reports running totals, and
pinning each change in a total on a play meant waiting for totals that trail the feed,
guessing which play a change belonged to, and getting it wrong when one change covered
two plays.

The league request already asks for `view=mSettings`, which carries
`settings.scoringSettings.scoringItems`: what one unit of each ESPN stat is worth, with
per-position overrides (a tight-end premium is an override keyed by the TE lineup
slot). `FantasyGameScorer` turns every play into a stat line per rostered player, keyed
by the same stat ids, and the points are the stat line times the table.

The stat ids were read off recorded data rather than taken from memory. A live Sunday
was polled every fifteen seconds and each change in a player's ESPN stat line was lined
up with the play that caused it and with ESPN's applied points per id: 3 is passing
yards at 0.04, 24 and 42 rushing and receiving yards at 0.1, 25 and 43 touchdowns at 6,
53 the catch that pays a point, 99 a defensive sack, 86 an extra point. Whole-game
totals settle the rest that matter most: summing the per-play points over the recorded
NE @ SEA feed gives exactly ESPN's week-one figures for Drake Maye (9.82, which pins 4 a
passing touchdown and -2 an interception) and Jaxon Smith-Njigba (26.2), and the
per-play stats add up to that game's box score for every player who touched the ball.
Ids not yet exercised by recorded data — kick buckets past 50 yards, the milestone
bonuses, defensive return touchdowns — follow the layout of the ones that were, and are
marked as such in `FantasyStat`.

- **By role, not by name.** The passer and the catcher, the runner, the kicker: a
  tackler in brackets or a player named in a penalty is never credited. Names follow
  play text's rules — it drops the `Jr.` and `III` rosters keep, and where one game's
  text has both `B.Robinson` and `Bi.Robinson`, the longer form is Bijan's.
- **Nothing is guessed.** A play wiped out by a flag scores nothing, a flag enforced
  after the play leaves its yards alone, a play under review scores nothing until the
  ruling replaces it, and a play with a lateral is skipped because the text cannot say
  how the yards split.
- **The try counts once.** ESPN can post the extra point as a play of its own while the
  touchdown's text already ends with it.
- **Game totals.** A point per 10 rushing yards, a 100-yard game: the play that crosses
  the line takes it.
- **Team defenses** are never named, so they score on what their side did — sacks,
  picks, recoveries, blocked kicks, safeties, return touchdowns. Points-allowed and
  yards-allowed tiers belong to the game, not to a play, and are left out.
- **Chips for the whole game.** Because nothing depends on having watched the totals
  move, a game opened mid-afternoon has chips back to its first play, and a relaunch
  fills them back in as soon as the feeds load. Nothing is saved to disk.
- **Starters only**, per league: a player rostered in two leagues is worth what each
  league's table says. The matchup score, the players' totals and the win probability
  are still ESPN's own.

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
  a score — including when the score posts a poll before the play text, which used to
  send a plain `TD JAX` and then the pick-six as well.
- **Turnovers are read from the text as well as ESPN's flag**, which misses strip-sacks,
  muffed punts and kick-return fumbles, and counts missed field goals — those are called
  `ATL missed FG · N. Folk 45 yd` instead.
- **Plays under review wait for the ruling**, and plays wiped out by a flag never alert.
- **The red zone needs a team in possession.** ESPN reports the ball inside the 20 with
  no possession while a try or field goal is set up, which used to add a red zone banner
  to every score.

Fantasy alerts fire for starters on either side of your matchup — every touchdown, plus
any play worth at least a configurable threshold (6 points by default), so a Sunday
brings a handful of banners rather than hundreds. Each player alerts at most once per
play, per league, as soon as the play is in the feed, with what the play was worth in
that league's scoring. Plays that were already in the feed when the app first saw it,
and plays first seen more than a couple of minutes ago, get their chips but never
interrupt; a play under review waits for the ruling. A touchdown worth less than a
touchdown usually is (a league that gives nothing for throwing one) is held to the
threshold. The subtitle is fitted to its line, dropping a long league name first.
The body is the play from the player's side:

```
Yours · Ja'Marr Chase +12.4
TD · 26.7 total · You 78.2 – 71.5
14-yd catch from J. Burrow
```

NFL alerts are derived from the scoreboard — score deltas, `lastPlay` and `isRedZone` —
rather than from the play feed, so they work for every game on the slate rather than
only the one on screen. A game is never alerted on the first time it is seen, or the
first time after a gap of more than a couple of minutes in polling, so launching
mid-afternoon or waking the Mac does not replay what was missed.

## RedZone

A small always-on-top window that follows every live game at once, like NFL RedZone. It
features whichever game matters most right now — a team in the red zone, a fourth down
in range, a one-score game late, a score that just landed, or your fantasy starters
with the ball — with the field position, the last play and what it was worth to your
lineup. Under it, the key moments from every game; under those, every live score.

It folds into a one-line pill (`KC 17-14 BUF · 2&4 BUF 12 · Q4 2:11`) that snaps to
whichever screen corner you drag it to. It only shows while football is being played,
comes back on its own at the next kickoff, and remembers whether it was open, its size
and its corner across launches. Turn it on from the court icon in the panel's footer.

- **Switching is instant but not twitchy.** Another game has to outrank the featured
  one by a clear margin (more while the featured game is inside the 20), so two drives
  in the red zone do not trade places every poll; a game reaching the red zone or a
  score elsewhere still takes over at once.
- **It reads only the scoreboard.** No play-by-play requests; it just tightens the
  scoreboard poll while it is up.
- **NFL banners pause while it is on screen**, since it already shows every score and
  turnover. Fantasy banners still come through.

`FootballWidget --snapshot-redzone <directory>` renders the pill and the window
offscreen from a made-up slate, without asking ESPN for anything.

## Refresh rate

Polling follows what is actually happening:

| State | Interval |
|---|---|
| No games today | 30 min |
| Next kickoff more than 6 h off | 30 min |
| Games today, none live | 5 min (60 s inside 10 min of kickoff; 30 s once kickoff time passes) |
| Live, panel closed | 20 s |
| Live, panel open, or RedZone as a pill | 10 s |
| Live, RedZone expanded | 5 s (scoreboard only) |
| A game's detail open or pinned | 5 s |
| Scoreboard failing | 30 s, doubling to 5 min; 403/429 back off from 1 min to 10 min |

Every window asks for its own rate and the fastest one wins, so closing the panel no
longer drops a pinned game or RedZone back to the closed-panel rate.

The six-hour row exists because the slate is not always today's. Once a week has been
played out the panel is showing the next one (below), whose first kickoff can be two
days away — and nothing about a Thursday game moves on a Tuesday.

Opening or closing the panel reschedules the next poll against the new interval rather
than forcing one, so a quick look does not cost a round of fetches.

The play feed is the heavy request, around half a megabyte per game. The game on screen
gets it at the rate above. A game that is only followed because a starter in your
fantasy matchup is playing in it gets it when the scoreboard reports a play that its
feed does not have yet, and otherwise once a minute — the newest play is all that needs
scoring.

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
