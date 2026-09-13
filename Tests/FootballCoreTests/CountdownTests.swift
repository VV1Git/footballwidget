import Foundation
import Testing
@testable import FootballCore

private let now = Date(timeIntervalSince1970: 1_757_000_000)

private func inMinutes(_ minutes: Double) -> Date {
    now.addingTimeInterval(minutes * 60)
}

@Test func showsMinutesUnderAnHour() {
    #expect(Countdown.text(until: inMinutes(45), from: now) == "45m")
    #expect(Countdown.text(until: inMinutes(1), from: now) == "1m")
    #expect(Countdown.text(until: inMinutes(59), from: now) == "59m")
}

@Test func showsHoursAndMinutesOverAnHour() {
    #expect(Countdown.text(until: inMinutes(65), from: now) == "1:05")
    #expect(Countdown.text(until: inMinutes(185), from: now) == "3:05")
    #expect(Countdown.text(until: inMinutes(60), from: now) == "1:00")
}

@Test func showsDaysWhenItIsFarOut() {
    #expect(Countdown.text(until: inMinutes(60 * 24), from: now) == "1d")
    #expect(Countdown.text(until: inMinutes(60 * 24 * 3 + 30), from: now) == "3d")
}

@Test func vanishesOnceKickoffHasPassed() {
    #expect(Countdown.text(until: inMinutes(-1), from: now) == nil)
    #expect(Countdown.text(until: now, from: now) == nil)
}

/// The bug: a stale countdown. Advancing the clock must change the text, which it can
/// only do if `now` is an input rather than read from inside.
@Test func theTextActuallyChangesAsTimeAdvances() {
    let kickoff = inMinutes(90)
    let first = Countdown.text(until: kickoff, from: now)
    let later = Countdown.text(until: kickoff, from: now.addingTimeInterval(30 * 60))
    #expect(first == "1:30")
    #expect(later == "1:00")
    #expect(first != later)
}

@Test func ticksOnlyWhenTheMinuteRollsOver() {
    // 45 minutes and 20 seconds out: the text changes in 20 seconds.
    let kickoff = now.addingTimeInterval(45 * 60 + 20)
    let wait = Countdown.secondsUntilTextChanges(until: kickoff, from: now)
    #expect(abs(wait - 20) < 0.001)
}
