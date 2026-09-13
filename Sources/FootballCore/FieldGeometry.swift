import Foundation

/// One rendered row of the field ladder: a single play placed on the shared yard scale.
public struct LadderRow: Identifiable, Hashable, Sendable {
    public var id: String
    public var play: Play
    /// 0 = the driving team's own goal line, 1 = the end zone it is attacking.
    public var startX: Double
    public var endX: Double
    /// Position in the drive, counting snaps only — 1, 2, 3… Nil for the drive-start
    /// marker, which is not a play. ESPN's own `sequenceNumber` is a global six-digit
    /// counter, not useful as a label.
    public var number: Int?
    /// A kickoff/punt reception that only marks where the drive began.
    public var isDriveStart: Bool
    /// The ball changed hands during the play, so `endX` is in the other team's frame.
    public var flipsFrame: Bool

    public var isNoGain: Bool { abs(endX - startX) < 0.0005 }
    public var isBackwards: Bool { endX < startX }

    public init(id: String, play: Play, startX: Double, endX: Double,
                number: Int? = nil, isDriveStart: Bool, flipsFrame: Bool) {
        self.id = id
        self.play = play
        self.startX = startX
        self.endX = endX
        self.number = number
        self.isDriveStart = isDriveStart
        self.flipsFrame = flipsFrame
    }
}

public enum FieldGeometry {

    // Play type ids observed in ESPN's feed. Derived by scanning a full game rather
    // than guessing: matching on `type.text` does not work because the casing is
    // inconsistent ("Two-minute warning" vs "End of Half").

    /// Clock events, not snaps. They report `start.yardsToEndzone == 0` with a real
    /// `end`, so they draw as full-width bars if they are not filtered out.
    public static let administrativeTypeIDs: Set<String> = [
        "2",   // End Period
        "21",  // Timeout
        "65",  // End of Half
        "66",  // End of Game
        "74",  // Official Timeout
        "75",  // Two-minute warning
    ]

    /// Measured from the *kicking* team's frame.
    public static let kickoffTypeIDs: Set<String> = ["53"]

    /// Genuine turnovers — worth alerting on. A punt changes possession but is not
    /// one, so this is deliberately narrower than `changeOfPossessionTypeIDs`.
    public static let turnoverTypeIDs: Set<String> = [
        "26",  // Pass Interception Return
        "29",  // Fumble Recovery (Opponent)
        "60",  // Missed Field Goal Return
    ]

    /// Ball changes hands inside the play, so the end node flips frame.
    public static let changeOfPossessionTypeIDs: Set<String> = [
        "52",  // Punt
        "26",  // Pass Interception Return
        "29",  // Fumble Recovery (Opponent)
        "36",  // Blocked Punt
        "60",  // Missed Field Goal Return
    ]

    // MARK: - Classification

    public static func classify(
        typeID: String?,
        isTurnover: Bool,
        start: PlayNode,
        end: PlayNode
    ) -> PlayKind {
        if let typeID {
            if administrativeTypeIDs.contains(typeID) { return .administrative }
            if kickoffTypeIDs.contains(typeID) { return .kickoff }
            if changeOfPossessionTypeIDs.contains(typeID) { return .changeOfPossession }
        }
        if isTurnover { return .changeOfPossession }
        // Defensive net for play types we have not catalogued: an unknown event that
        // starts nowhere and gains nothing is a clock stoppage, not a snap.
        if start.yardsToEndzone == 0, let e = end.yardsToEndzone, e != 0 {
            return .administrative
        }
        return .scrimmage
    }

    // MARK: - Coordinates

    /// Maps a play endpoint onto 0...1 in the driving team's frame.
    ///
    /// ESPN measures `yardsToEndzone` against whichever end zone the team named in the
    /// node is attacking. That team is *not* always the one on offense — it flips on
    /// kickoffs, punts and turnover returns — so a node attributed to the other team
    /// has to be mirrored before it can share a scale with the rest of the drive.
    public static func normalizedX(node: PlayNode, offenseTeamID: String?) -> Double? {
        guard let yards = node.yardsToEndzone else { return nil }
        let sameFrame = node.teamID == nil || offenseTeamID == nil || node.teamID == offenseTeamID
        let x = sameFrame ? (100.0 - Double(yards)) / 100.0 : Double(yards) / 100.0
        return min(max(x, 0), 1)
    }

    public static func isFrameFlipped(start: PlayNode, end: PlayNode) -> Bool {
        guard let s = start.teamID, let e = end.teamID else { return false }
        return s != e
    }

    // MARK: - Ladder

    /// Turns a drive into the rows the field map draws, in play order.
    public static func rows(for drive: Drive) -> [LadderRow] {
        let offense = drive.teamID
        var rows: [LadderRow] = []
        var snapNumber = 0

        for play in drive.plays {
            guard play.kind != .administrative else { continue }

            let sx = normalizedX(node: play.start, offenseTeamID: offense)
            let ex = normalizedX(node: play.end, offenseTeamID: offense)

            if play.kind == .kickoff {
                // Only the end of a kickoff is meaningful in the offense's frame:
                // it is where this drive actually starts.
                guard let ex else { continue }
                rows.append(LadderRow(id: play.id, play: play, startX: ex, endX: ex,
                                      number: nil, isDriveStart: true, flipsFrame: false))
                continue
            }

            guard let sx, let ex else { continue }
            snapNumber += 1
            rows.append(LadderRow(
                id: play.id,
                play: play,
                startX: sx,
                endX: ex,
                number: snapNumber,
                isDriveStart: false,
                flipsFrame: isFrameFlipped(start: play.start, end: play.end)
            ))
        }
        return rows
    }

    // MARK: - Field furniture

    /// Yard numbers along the field, as (x in 0...1, label).
    public static let yardTicks: [(x: Double, label: String)] = [
        (0.1, "10"), (0.2, "20"), (0.3, "30"), (0.4, "40"), (0.5, "50"),
        (0.6, "40"), (0.7, "30"), (0.8, "20"), (0.9, "10"),
    ]

    /// Every 5-yard line, for the faint stripes behind the rows.
    public static let minorLines: [Double] = stride(from: 0.05, through: 0.95, by: 0.05).map { $0 }

    // MARK: - Text rendering (tests + `--selftest`)

    /// Renders a drive as the same ASCII ladder used to validate the geometry.
    /// Keeping this next to the real math means a test can assert on bar positions
    /// without standing up any SwiftUI.
    public static func asciiLadder(for drive: Drive, width: Int = 48) -> String {
        var lines: [String] = []
        lines.append("DRIVE: \(drive.teamAbbreviation)  \(drive.result)  (\(drive.yards) yds)")
        lines.append("|" + String(repeating: "-", count: max(width - 2, 0)) + "|")

        for row in rows(for: drive) {
            var cells = [Character](repeating: " ", count: width)
            let a = Int(row.startX * Double(width - 1))
            let b = Int(row.endX * Double(width - 1))

            if row.isDriveStart {
                cells[b] = "#"
                lines.append(String(cells) + " | DRIVE START")
                continue
            }

            let fill: Character = row.flipsFrame ? "~" : "="
            for i in min(a, b)...max(a, b) { cells[i] = fill }
            cells[a] = "|"
            if b > a { cells[b] = ">" } else if b < a { cells[b] = "<" } else { cells[a] = "x" }

            let label = row.flipsFrame
                ? "TURNOVER"
                : "\(row.play.typeText.prefix(16)) \(row.play.yardageLabel)"
            let dd = (row.play.downDistanceText ?? "").prefix(16)
            lines.append(String(cells) + " | \(dd.padded(to: 16)) \(label)")
        }
        return lines.joined(separator: "\n")
    }
}

private extension StringProtocol {
    func padded(to n: Int) -> String {
        let s = String(self)
        return s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}
