import Foundation

/// The handful of facts a notification leads with, read out of one ESPN play description.
///
/// A macOS banner shows its title and subtitle on one line each and only a couple of lines
/// of body, so "who scored" and "whose ball it is now" cannot stay buried in prose like
/// `(Shotgun) J.Burrow pass short right to J.Chase for 14 yards, TOUCHDOWN. E.McPherson
/// extra point is GOOD, Center-C.Adomitis, Holder-K.Huber.`
///
/// The parser is deliberately literal. Anything it does not recognise is left nil rather
/// than guessed, because a banner naming the wrong player is worse than one naming nobody —
/// callers fall back to generic wording ("TD CIN"). It was built against ~22,000 real plays
/// from ESPN's summary feed plus live scoreboard polls, and the phrasing it relies on is the
/// NFL gamebook's: `RECOVERED by` in capitals means the *other* team got the ball,
/// `recovered by` in lower case means the fumbling team kept it.
public struct PlaySummary: Sendable, Equatable {

    /// What was attempted. A pick-six is `.interception` with `touchdown` set.
    public enum Kind: Sendable, Equatable {
        case pass
        case incompletePass
        case interception
        case rush
        case sack
        case punt
        case kickoff
        case fieldGoal(KickResult)
        case extraPoint(good: Bool)
        case twoPointConversion(good: Bool)
        case safety
        /// Wiped out by a penalty (`NULLIFIED`, `- No Play`), or a flag with no snap.
        case noPlay
        /// ESPN's `*** play under review ***` placeholder. The real text replaces it.
        case underReview
        case unknown
    }

    public enum KickResult: Sendable, Equatable { case good, missed, blocked }

    /// How the defence (or the kicking team) came away with the ball.
    public enum Takeaway: Sendable, Equatable { case interception, fumble, muffedKick, blockedKick }

    public enum Touchdown: Sendable, Equatable {
        case pass, rush
        case interceptionReturn, fumbleReturn, puntReturn, kickoffReturn
        case blockedKickReturn, missedFieldGoalReturn
        /// A loose ball fallen on in the end zone, by either side.
        case fumbleRecovery
        /// Six points, but not in a shape worth naming anyone for — a lateral, say.
        case other
    }

    /// The conversion attempt ESPN appends to a touchdown, or posts on its own.
    public enum Try: Sendable, Equatable {
        case extraPointGood, extraPointMissed, twoPointGood, twoPointFailed, defensiveTwoPoint
    }

    public var kind: Kind
    /// Set only when the ball finished the play with the other team.
    public var takeaway: Takeaway?
    public var touchdown: Touchdown?
    public var tryResult: Try?

    // Names are for display: "J. Chase", "A. St. Brown", or a full name where ESPN gave one.
    /// Who crossed the goal line, kicked the field goal, or was credited with the safety.
    public var scorer: String?
    public var passer: String?
    /// The catcher on a completion, the intended receiver otherwise.
    public var receiver: String?
    public var rusher: String?
    public var kicker: String?
    public var fumbledBy: String?
    public var forcedBy: String?
    /// The interceptor, or whoever recovered the loose ball for the other side.
    public var recoveredBy: String?
    /// The team that took the ball away, *as abbreviated in play text* — which is not always
    /// the scoreboard's abbreviation ("BLT" for BAL). See `scoreboardAbbreviation(_:)`.
    public var recoveringTeam: String?

    /// Gain on a pass or run, distance of a field goal, length of a touchdown.
    public var yards: Int?
    /// Distance an interception or recovery was run back.
    public var returnYards: Int?
    /// "Wide Left" on a missed kick.
    public var detail: String?

    /// Who took part in a try written onto the end of the play: the kicker of the extra
    /// point, or the passer, catcher or runner of a two-point conversion. A try posted on
    /// its own fills `kicker`, `passer`, `receiver` and `rusher` instead.
    public var tryKicker: String?
    public var tryPasser: String?
    public var tryReceiver: String?
    public var tryRusher: String?

    public init(kind: Kind = .unknown) {
        self.kind = kind
    }

    public var isTurnover: Bool { takeaway != nil }

    // MARK: - Parsing

    public static func parse(_ raw: String?) -> PlaySummary {
        var play = PlaySummary()
        // The live scoreboard sometimes breaks a play across lines ("TOUCHDOWN.\nPenalty on
        // TEN…") and later rewrites it without the break.
        guard var text = raw?.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return play }

        if text.range(of: "under review", options: .caseInsensitive) != nil,
           Rx.name.matches(in: text).isEmpty {
            play.kind = .underReview
            return play
        }

        // A replay reversal leaves the original call in front of the corrected one
        // ("…TOUCHDOWN.The Replay Official reviewed…REVERSED.(Shotgun) …to CLV 1 for 41
        // yards"). Only what follows the last reversal happened — unless only the try was
        // reviewed, in which case the touchdown in front of it still stands.
        if let reversal = text.range(of: "REVERSED.", options: .backwards) {
            let corrected = String(text[reversal.upperBound...]).trimmingCharacters(in: .whitespaces)
            let original = String(text[..<reversal.lowerBound])
            if let tryCut = tryStart(in: corrected), tryCut == corrected.startIndex,
               let originalTry = tryStart(in: original) {
                text = String(original[..<originalTry]) + corrected
            } else {
                text = corrected
            }
            guard !text.isEmpty else { return play }
        }

        if let summary = scoringSummary(text) { return summary }

        // The try is its own sentence at the end; parse it apart so a two-point pass is
        // never mistaken for the touchdown pass in front of it.
        var main = text
        if let cut = tryStart(in: text) {
            let segment = String(text[cut...])
            main = String(text[..<cut])
            play.tryResult = tryResult(segment)
            if main.trimmingCharacters(in: .whitespaces).isEmpty {
                return standaloneTry(segment, result: play.tryResult)
            }
            let conversion = standaloneTry(segment, result: play.tryResult)
            play.tryKicker = conversion.kicker
            play.tryPasser = conversion.passer
            play.tryReceiver = conversion.receiver
            play.tryRusher = conversion.rusher
        }

        // A safety enforced by penalty is written "…in End Zone, SAFETY - No Play." and
        // still scores; every other "No Play" means nothing on the snap counted.
        let isSafety = main.contains("SAFETY") && !main.contains("SAFETY NULLIFIED")
        if main.contains("NULLIFIED") || (main.contains("No Play") && !isSafety) {
            return PlaySummary(kind: .noPlay)
        }

        classify(main, into: &play)
        if isSafety {
            play.kind = .safety
            play.scorer = Rx.safetyCredit.first(in: main)?[1].map(display)
        }
        readTakeaway(main, into: &play)
        if main.contains("TOUCHDOWN") { readTouchdown(main, into: &play) }
        return play
    }

    /// The base play, before anything that happened to the ball afterwards.
    private static func classify(_ main: String, into play: inout PlaySummary) {
        if let m = Rx.fieldGoal.first(in: main) {
            play.kicker = m[1].map(display)
            play.yards = m[2].flatMap { Int($0) }
            switch m[3] {
            case "GOOD":
                play.kind = .fieldGoal(.good)
                play.scorer = play.kicker
            case "BLOCKED":
                play.kind = .fieldGoal(.blocked)
            default:
                play.kind = .fieldGoal(.missed)
                play.detail = m[4]
            }
        } else if Rx.punt.first(in: main) != nil {
            play.kind = .punt
        } else if Rx.kickoff.first(in: main) != nil {
            play.kind = .kickoff
        } else if let m = Rx.interception.first(in: main) {
            play.kind = .interception
            play.recoveredBy = m[1].map(display)
            play.passer = Rx.passer.first(in: main)?[1].map(display)
            play.receiver = Rx.intendedFor.first(in: main)?[1].map(display)
        } else if let m = Rx.sack.first(in: main) {
            play.kind = .sack
            play.passer = m[1].map(display)
        } else if let m = Rx.spike.first(in: main) {
            play.kind = .incompletePass
            play.passer = m[1].map(display)
        } else if let m = Rx.incomplete.first(in: main) {
            play.kind = .incompletePass
            play.passer = m[1].map(display)
            play.receiver = m[2].map(display)
        } else if let m = Rx.completion.first(in: main) {
            play.kind = .pass
            play.passer = m[1].map(display)
            play.receiver = m[2].map(display)
            play.yards = yards(in: main, after: m.range.upperBound)
        } else if let m = Rx.rush.first(in: main) {
            play.kind = .rush
            play.rusher = m[1].map(display)
            play.yards = yards(in: main, after: m.range.upperBound)
        }
    }

    /// Works out whether the ball ended with the other team, counting every change of
    /// hands in the play: an interception returned and fumbled back is two changes and no
    /// turnover, which reading only the first sentence would get wrong.
    private static func readTakeaway(_ main: String, into play: inout PlaySummary) {
        let interceptions = Rx.interception.matches(in: main)
        let fumbles = ranges(of: "FUMBLES", in: main)
        let muffs = ranges(of: "MUFFS", in: main)
        // A recovery only changes hands if something came loose first. An onside kick
        // reads "RECOVERED by CAR-D.Richardson" with nothing before it, and the kicking
        // team keeping its own kick is not a takeaway.
        let causes = (fumbles + muffs + ranges(of: "BLOCKED", in: main)).map(\.lowerBound)
        let recoveries = Rx.opponentRecovery.matches(in: main).filter { recovery in
            causes.contains { $0 < recovery.range.lowerBound }
        }

        // Who lost it, when there is only one loose ball to talk about.
        let losses = (fumbles + muffs).sorted { $0.lowerBound < $1.lowerBound }
        if losses.count == 1, let loss = losses.first {
            play.fumbledBy = carrier(before: loss.lowerBound, in: main)
            if !fumbles.isEmpty {
                play.forcedBy = Rx.forcedBy.first(in: main)?[1].map(display)
            }
        }

        guard (interceptions.count + recoveries.count) % 2 == 1 else {
            if !interceptions.isEmpty || !recoveries.isEmpty {
                // Went back and forth: nobody's takeaway, and the names would mislead.
                play.recoveredBy = nil
            }
            return
        }

        let lastInterception = interceptions.last
        let lastRecovery = recoveries.last
        if let recovery = lastRecovery,
           lastInterception.map({ $0.range.lowerBound < recovery.range.lowerBound }) ?? true {
            play.recoveringTeam = recovery[1]
            play.recoveredBy = recovery[2].map(display)
            let before = main[..<recovery.range.lowerBound]
            let cause = [("FUMBLES", Takeaway.fumble), ("MUFFS", .muffedKick), ("BLOCKED", .blockedKick)]
                .compactMap { word, kind in before.range(of: word, options: .backwards).map { ($0.lowerBound, kind) } }
                .max { $0.0 < $1.0 }
            play.takeaway = cause?.1 ?? .fumble
            play.returnYards = returnYards(in: main, after: recovery.range.upperBound)
        } else if let interception = lastInterception {
            play.takeaway = .interception
            play.recoveredBy = interception[1].map(display)
            play.returnYards = returnYards(in: main, after: interception.range.upperBound)
        }
    }

    private static func readTouchdown(_ main: String, into play: inout PlaySummary) {
        if play.takeaway == nil, let m = Rx.passingTouchdown.first(in: main) {
            play.touchdown = .pass
            play.passer = m[1].map(display)
            play.receiver = m[2].map(display)
            play.scorer = play.receiver
            play.yards = touchdownYards(m[3])
            return
        }
        guard let m = Rx.touchdownRunner.first(in: main), let who = m[1] else {
            // "RECOVERED by HST-W.Anderson at SEA -5. TOUCHDOWN." — fallen on in the end
            // zone, so there is no run to describe but the scorer is plain.
            if play.takeaway == .fumble, let recovery = Rx.endZoneRecovery.first(in: main),
               recovery[1].map(display) == play.recoveredBy {
                play.touchdown = .fumbleRecovery
                play.scorer = play.recoveredBy
            } else {
                play.touchdown = .other
            }
            return
        }
        let distance = touchdownYards(m[3])
        let ranWithDirection = !(m[2] ?? "").isEmpty

        if let takeaway = play.takeaway {
            switch takeaway {
            case .interception: play.touchdown = .interceptionReturn
            case .fumble, .muffedKick: play.touchdown = .fumbleReturn
            case .blockedKick: play.touchdown = .blockedKickReturn
            }
            play.returnYards = distance
            // Only name the returner if he is the one who took it away; a lateral after
            // the pick means somebody else scored, and the text is easy to misread.
            play.scorer = display(who) == play.recoveredBy ? play.recoveredBy : nil
            play.yards = play.scorer == nil ? nil : distance
            return
        }

        switch play.kind {
        case .punt:
            play.touchdown = .puntReturn
        case .kickoff:
            play.touchdown = .kickoffReturn
        case .fieldGoal(.missed):
            play.touchdown = .missedFieldGoalReturn
        case .rush where ranWithDirection && play.rusher == display(who):
            play.touchdown = .rush
        default:
            play.touchdown = .other
            return
        }
        play.scorer = display(who)
        play.yards = distance
        if play.touchdown != .rush { play.returnYards = distance }
    }

    // MARK: - The try

    private static func tryStart(in text: String) -> String.Index? {
        var starts: [String.Index] = []
        if let m = Rx.extraPoint.first(in: text) { starts.append(m.range.lowerBound) }
        for marker in ["TWO-POINT CONVERSION ATTEMPT", "DEFENSIVE TWO-POINT ATTEMPT"] {
            if let r = text.range(of: marker) { starts.append(r.lowerBound) }
        }
        return starts.min()
    }

    private static func tryResult(_ segment: String) -> Try? {
        // A flag on the try means it is being run again.
        if segment.contains("No Play") { return nil }
        var offense = Substring(segment)
        if let defensive = segment.range(of: "DEFENSIVE TWO-POINT ATTEMPT") {
            if segment[defensive.upperBound...].contains("ATTEMPT SUCCEEDS") { return .defensiveTwoPoint }
            offense = segment[..<defensive.lowerBound]
        }
        if offense.contains("TWO-POINT CONVERSION ATTEMPT") {
            if offense.contains("ATTEMPT SUCCEEDS") { return .twoPointGood }
            if offense.contains("ATTEMPT FAILS") { return .twoPointFailed }
            return nil
        }
        if let m = Rx.extraPoint.first(in: String(offense)) {
            return m[2] == "GOOD" ? .extraPointGood : .extraPointMissed
        }
        return nil
    }

    private static func standaloneTry(_ segment: String, result: Try?) -> PlaySummary {
        var play = PlaySummary()
        play.tryResult = result
        switch result {
        case .extraPointGood?, .extraPointMissed?:
            play.kind = .extraPoint(good: result == .extraPointGood)
            play.kicker = Rx.extraPoint.first(in: segment)?[1].map(display)
        case .twoPointGood?, .twoPointFailed?:
            play.kind = .twoPointConversion(good: result == .twoPointGood)
            if result == .twoPointGood {
                if let m = Rx.twoPointCatch.first(in: segment) {
                    play.passer = m[1].map(display)
                    play.receiver = m[2].map(display)
                    play.scorer = play.receiver
                } else if let m = Rx.twoPointRun.first(in: segment) {
                    play.rusher = m[1].map(display)
                    play.scorer = play.rusher
                }
            }
        case .defensiveTwoPoint?:
            play.kind = .twoPointConversion(good: false)
        case nil:
            play.kind = segment.contains("No Play") ? .noPlay : .unknown
        }
        return play
    }

    // MARK: - Scoring-summary phrasing

    /// ESPN's scoring summaries, and the separate try plays on the live scoreboard, use a
    /// second style with full names: `(Cairo Santos Kick)`, `Daron Payne Safety`,
    /// `Eli Raridon 2 Yd pass from Drake Maye (Andy Borregales Kick)`.
    private static func scoringSummary(_ text: String) -> PlaySummary? {
        var play = PlaySummary()
        if let m = Rx.summaryKick.first(in: text) {
            play.kind = .extraPoint(good: true)
            play.tryResult = .extraPointGood
            play.kicker = m[1]
            return play
        }
        if let m = Rx.summaryMissedKick.first(in: text) {
            play.kind = .extraPoint(good: false)
            play.tryResult = .extraPointMissed
            play.kicker = m[1]
            return play
        }
        if let m = Rx.summaryTwoPoint.first(in: text) {
            play.kind = .twoPointConversion(good: true)
            play.tryResult = .twoPointGood
            if let receiver = m[3] {
                play.passer = m[1]
                play.receiver = receiver
                play.scorer = receiver
            } else {
                play.rusher = m[1]
                play.scorer = m[1]
            }
            return play
        }
        if Rx.summaryTwoPointFailed.first(in: text) != nil {
            play.kind = .twoPointConversion(good: false)
            play.tryResult = .twoPointFailed
            return play
        }
        if let m = Rx.summarySafety.first(in: text) {
            play.kind = .safety
            if let who = m[1], !who.localizedCaseInsensitiveContains("penalty") { play.scorer = who }
            return play
        }
        guard let m = Rx.summaryScore.first(in: text), let who = m[1], let how = m[3]?.lowercased()
        else { return nil }

        let distance = m[2].flatMap { Int($0) }
        play.scorer = who
        play.yards = distance
        if how.hasPrefix("pass from") {
            play.kind = .pass
            play.touchdown = .pass
            play.passer = m[4]
            play.receiver = who
        } else if how == "rush" || how == "run" {
            play.kind = .rush
            play.touchdown = .rush
            play.rusher = who
        } else if how == "field goal" {
            play.kind = .fieldGoal(.good)
            play.kicker = who
        } else {
            play.returnYards = distance
            switch how {
            case "interception return":
                play.kind = .interception
                play.takeaway = .interception
                play.touchdown = .interceptionReturn
                play.recoveredBy = who
            case "fumble return":
                play.takeaway = .fumble
                play.touchdown = .fumbleReturn
                play.recoveredBy = who
            case "fumble recovery":
                // Either side: "Tyler Lockett 0 Yd Fumble Recovery" was the offense
                // falling on its own ball in the end zone. Say what happened, not who lost it.
                play.touchdown = .fumbleRecovery
            case "punt return":
                play.kind = .punt
                play.touchdown = .puntReturn
            case "kickoff return", "kick return":
                play.kind = .kickoff
                play.touchdown = .kickoffReturn
            default:
                play.touchdown = .other
            }
        }
        if let conversion = m[5] {
            if conversion.hasSuffix(" Kick") {
                play.tryResult = .extraPointGood
                play.tryKicker = String(conversion.dropLast(" Kick".count))
            } else if conversion.localizedCaseInsensitiveContains("PAT") {
                play.tryResult = .extraPointMissed
            } else if conversion.hasSuffix("for Two-Point Conversion") {
                play.tryResult = .twoPointGood
                if let two = Rx.summaryTwoPoint.first(in: "(\(conversion))") {
                    if let receiver = two[3] {
                        play.tryPasser = two[1]
                        play.tryReceiver = receiver
                    } else {
                        play.tryRusher = two[1]
                    }
                }
            } else if conversion.localizedCaseInsensitiveContains("Conversion Failed") {
                play.tryResult = .twoPointFailed
            }
        }
        return play
    }

    // MARK: - Pieces

    /// `J.Smith-Njigba` → `J. Smith-Njigba`. Full names pass through untouched.
    public static func display(_ token: String) -> String {
        guard let dot = token.firstIndex(of: "."),
              token.distance(from: token.startIndex, to: dot) <= 3,
              let next = token.index(dot, offsetBy: 1, limitedBy: token.endIndex),
              next < token.endIndex, token[next] != " "
        else { return token }
        return String(token[...dot]) + " " + String(token[next...])
    }

    /// Whether a display name from a play ("J. Chase", "Bi. Robinson", "Jalen Nailor")
    /// refers to this player. Letters only, so "Smith-Njigba" and "SmithNjigba" agree.
    public static func name(_ shown: String?, matchesFirst first: String, last: String) -> Bool {
        guard let shown, !shown.isEmpty else { return false }
        let surname = normalize(withoutSuffix(last))
        guard !surname.isEmpty else { return false }
        if let dot = shown.range(of: ". "), shown.distance(from: shown.startIndex, to: dot.lowerBound) <= 3 {
            let initial = shown[..<dot.lowerBound].lowercased()
            return first.lowercased().hasPrefix(initial)
                && normalize(withoutSuffix(String(shown[dot.upperBound...]))) == surname
        }
        return normalize(withoutSuffix(shown)) == normalize(first) + surname
    }

    /// Play text abbreviates some teams differently from the scoreboard. Only the ones
    /// actually seen in ESPN's feed; anything else is returned unchanged.
    public static func scoreboardAbbreviation(_ textAbbreviation: String) -> String {
        [
            "BLT": "BAL", "HST": "HOU", "CLV": "CLE", "ARZ": "ARI",
            "LA": "LAR", "WAS": "WSH", "JAC": "JAX",
        ][textAbbreviation] ?? textAbbreviation
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased().filter(\.isLetter)
    }

    private static func withoutSuffix(_ name: String) -> String {
        let suffixes = [" Jr.", " Jr", " Sr.", " Sr", " II", " III", " IV", " V"]
        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// The player who had the ball just before `index`: the last name not inside a
    /// tackle credit `(…)` / `[…]` and not a `SEA-`/`Center-` style label.
    private static func carrier(before index: String.Index, in text: String) -> String? {
        var depth = 0
        var depthAt: [String.Index: Int] = [:]
        var i = text.startIndex
        while i < index {
            depthAt[i] = depth
            switch text[i] {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth - 1)
            default: break
            }
            i = text.index(after: i)
        }
        let candidates = Rx.name.matches(in: text).filter { m in
            let start = m.range.lowerBound
            guard start < index, depthAt[start] == 0 else { return false }
            return start == text.startIndex || text[text.index(before: start)] != "-"
        }
        return candidates.last?[0].map(display)
    }

    private static func yards(in text: String, after index: String.Index) -> Int? {
        guard let m = Rx.gain.first(in: text, from: index) else { return nil }
        return m[1].flatMap { Int($0) } ?? 0
    }

    /// The return distance, read only up to the next loose ball or flag so a penalty's
    /// yardage is never taken for the runback.
    private static func returnYards(in text: String, after index: String.Index) -> Int? {
        var end = text.endIndex
        for stop in ["FUMBLES", "PENALTY", "Penalty", "Touchback"] {
            if let r = text.range(of: stop, range: index..<text.endIndex), r.lowerBound < end {
                end = r.lowerBound
            }
        }
        let window = String(text[index..<end])
        return yards(in: window, after: window.startIndex)
    }

    private static func touchdownYards(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int(text) ?? 0   // "no gain"
    }

    private static func ranges(of word: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: word, range: from..<text.endIndex) {
            found.append(r)
            from = r.upperBound
        }
        return found
    }
}

// MARK: - Patterns

/// Compiled once; `NSRegularExpression` is safe to share once built.
private enum Rx {
    /// A gamebook name: `J.Chase`, `Bi.Robinson`, `J.Smith-Njigba`, `H.To'oTo'o`,
    /// `A.St. Brown`, `L.Van Ness`. The look-behind stops `A.St. Brown` also matching at `St.`.
    static let n = "(?<![A-Za-z.])[A-Z][a-z]{0,2}\\.(?:St\\. |Van )?[A-Z][A-Za-z'\\-]*[A-Za-z]"
    static let N = "(\(n))"
    /// A full name in scoring-summary style: `Kenny Moore II`, `Amon-Ra St. Brown`.
    static let F = "([A-Z][A-Za-z'.\\-]*(?: [A-Z][A-Za-z'.\\-]*)*)"
    static let distance = "(?:(\\d+) yards?|no gain)"

    static let name = Pattern(n)
    static let fieldGoal = Pattern(
        "\(N) (\\d+) yard field goal is (GOOD|No Good|BLOCKED)(?:, ((?:Wide|Hit|Short|Blocked)[A-Za-z ]*))?"
    )
    static let extraPoint = Pattern("(?:\(N) )?extra point is (GOOD|No Good|Blocked|Aborted)")
    static let punt = Pattern("\(N) (?:punts (?:-?\\d+ yards?|to)|punt is BLOCKED)")
    static let kickoff = Pattern("\(N) kicks ")
    static let interception = Pattern("INTERCEPTED by \(N)")
    static let passer = Pattern("\(N) pass ")
    static let intendedFor = Pattern("intended for \(N)")
    static let sack = Pattern("\(N) sacked")
    static let spike = Pattern("\(N) spiked")
    /// The direction words must not swallow "to", or the optional receiver never matches.
    static let incomplete = Pattern("\(N) pass incomplete(?: (?!to\\b)[a-z]+)*(?: to \(N))?")
    static let completion = Pattern("\(N) pass(?: [a-z]+)* to \(N)")
    static let rush = Pattern(
        "\(N) (?:scrambles )?(?:up the middle|left end|right end|left tackle|right tackle|left guard|right guard|kneels)"
    )
    static let gain = Pattern("for (?:(-?\\d+) yards?|no gain)")
    static let passingTouchdown = Pattern("\(N) pass(?: [a-z]+)* to \(N) for \(distance), TOUCHDOWN")
    /// The name directly in front of `for N yards, TOUCHDOWN`, with any run direction.
    static let touchdownRunner = Pattern("\(N)((?: [a-z]+)*) for \(distance), TOUCHDOWN")
    /// Capital `RECOVERED` is the gamebook's marker for the other side getting the ball.
    static let opponentRecovery = Pattern("RECOVERED by ([A-Z]{2,3})-\(N)")
    static let endZoneRecovery = Pattern("RECOVERED by [A-Z]{2,3}-\(N) (?:at [A-Z]{2,3} -\\d+|in End Zone)\\. TOUCHDOWN")
    static let forcedBy = Pattern("FUMBLES \\(\(N)\\)")
    static let safetyCredit = Pattern("SAFETY \\(\(N)\\)")
    static let twoPointCatch = Pattern("\(N) pass to \(N) is complete")
    static let twoPointRun = Pattern("\(N) rushes")

    static let summaryKick = Pattern("^\\(\(F) Kick\\)$")
    static let summaryMissedKick = Pattern("^\\(\(F) (?:PAT|Extra Point) (?:Failed|blocked|Blocked|No Good|Missed)\\)$")
    static let summaryTwoPoint = Pattern("^\\(\(F) (Pass|Run|Rush)(?: to \(F))? for Two-Point Conversion\\)$")
    static let summaryTwoPointFailed = Pattern("^\\(Two-Point (?:Pass |Run |Rush )?Conversion Failed\\)$")
    /// `Daron Payne Safety`, or a penalty's wording ending `for a Safety`, which credits nobody.
    static let summarySafety = Pattern("^(?:\(F) )?Safety$|^[A-Z][A-Za-z ]* for (?:a )?Safety$")
    /// Only the play words are case-insensitive ("pass from" but "Rush"); names must
    /// still start with a capital or any sentence would pass for one.
    static let summaryScore = Pattern(
        "^\(F) (\\d+) Yd ((?i:pass from) \(F)|(?i:Rush|Run|Interception Return|Fumble Recovery|Fumble Return|Punt Return|Kickoff Return|Kick Return|Field Goal))\\s*(?:\\((.*)\\))?\\s*$"
    )
}

private struct Pattern {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        regex = try! NSRegularExpression(pattern: pattern)
    }

    struct Match {
        let range: Range<String.Index>
        let groups: [String?]
        /// Capture group `i`; 0 is the whole match.
        subscript(i: Int) -> String? { i < groups.count ? groups[i] : nil }
    }

    func first(in text: String, from start: String.Index? = nil) -> Match? {
        let lower = start ?? text.startIndex
        let range = NSRange(lower..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range).flatMap { match(from: $0, in: text) }
    }

    func matches(in text: String) -> [Match] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match(from: $0, in: text) }
    }

    private func match(from result: NSTextCheckingResult, in text: String) -> Match? {
        guard let range = Range(result.range, in: text) else { return nil }
        let groups = (0..<result.numberOfRanges).map { i in
            Range(result.range(at: i), in: text).map { String(text[$0]) }
        }
        return Match(range: range, groups: groups)
    }
}
