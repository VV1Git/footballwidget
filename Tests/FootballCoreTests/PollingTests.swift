import Foundation
import Testing
@testable import FootballCore

// ESPN sends no ETag, so every poll comes back as a full 200. The store leans on
// `@Observable` skipping an assignment equal to the current value, so a poll that maps
// to the same model redraws nothing. That only holds if mapping is deterministic — no
// fresh UUIDs, no ordering that varies between decodes — so these pin it down against
// the recorded payloads.

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                             subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func mappedDetail() throws -> GameDetail {
    let dto = try JSONDecoder().decode(ESPNSummaryDTO.self, from: fixture("summary"))
    return ESPNMapper.detail(from: dto, gameID: "401872656")
}

private func mappedGames() throws -> [Game] {
    let dto = try JSONDecoder().decode(ESPNScoreboardDTO.self, from: fixture("scoreboard"))
    return ESPNMapper.games(from: dto)
}

// MARK: - Unchanged payloads map to equal models

@Test func unchangedPlayFeedMapsToAnEqualDetail() throws {
    // Two independent decodes, as two polls would be.
    #expect(try mappedDetail() == mappedDetail())
}

@Test func newPlayMakesTheDetailDifferent() throws {
    let before = try mappedDetail()
    var after = before
    var drive = try #require(after.drives.first)
    let last = try #require(drive.plays.last)
    var next = last
    next.id = last.id + "-next"
    drive.plays.append(next)
    after.drives[0] = drive
    #expect(before != after)
}

@Test func unchangedScoreboardMapsToEqualGames() throws {
    #expect(try mappedGames() == mappedGames())
}

/// A clock tick changes one game, and only that game's row should count as changed.
@Test func clockTickChangesOnlyThatGame() throws {
    let before = try mappedGames()
    var after = before
    after[0].displayClock = "0:01"
    #expect(before != after)
    let changed = zip(before, after).filter { $0 != $1 }
    #expect(changed.count == 1)
    #expect(changed.first?.1.id == before[0].id)
}

// MARK: - FetchGate

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test func gateSkipsAFetchAlreadyInFlight() {
    var gate = FetchGate(freshness: 4)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    #expect(gate.isInFlight("g1"))
    // Opening a game while the poll loop is already fetching it.
    let opened = gate.begin("g1", now: t0.addingTimeInterval(0.2))
    #expect(!opened)
    // Other games are unaffected.
    let other = gate.begin("g2", now: t0.addingTimeInterval(0.2))
    #expect(other)
}

@Test func gateSharesAFetchMadeMomentsAgo() {
    var gate = FetchGate(freshness: 4)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    gate.end("g1")
    #expect(!gate.isInFlight("g1"))
    // The pinned window's loop landing two seconds after the store's.
    let pinned = gate.begin("g1", now: t0.addingTimeInterval(2))
    #expect(!pinned)
}

@Test func gateLetsADueLoopFetchAgain() {
    var gate = FetchGate(freshness: 4)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    gate.end("g1")
    // The fastest poll interval is five seconds, so a due loop is never starved.
    let due = gate.begin("g1", now: t0.addingTimeInterval(5))
    #expect(due)
}

@Test func skippedFetchDoesNotPushTheWindowBack() {
    var gate = FetchGate(freshness: 4)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    gate.end("g1")
    let early = gate.begin("g1", now: t0.addingTimeInterval(3))
    #expect(!early)
    // Measured from the fetch that ran, not from the one that was skipped.
    let later = gate.begin("g1", now: t0.addingTimeInterval(4.5))
    #expect(later)
}

@Test func gateRemembersWhenAFetchLastStarted() {
    var gate = FetchGate(freshness: 4)
    #expect(gate.lastStarted("g1") == nil)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    #expect(gate.lastStarted("g1") == t0)
}

/// A retry after a feed came back a play short is meant to land a second or two after
/// the fetch that missed, which the ordinary freshness window would refuse.
@Test func retryIsNotHeldToTheFreshnessWindow() {
    var gate = FetchGate(freshness: 4)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    gate.end("g1")
    let retry = gate.beginRetry("g1")
    #expect(retry)
}

@Test func retrySkipsAFetchAlreadyInFlight() {
    var gate = FetchGate(freshness: 4)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    let retry = gate.beginRetry("g1")
    #expect(!retry)
    gate.end("g1")
    let again = gate.beginRetry("g1")
    #expect(again)
}

/// Retries must not eat into the poll loop's window: were `lastStarted` moved by a
/// retry, the next due poll could land inside the freshness window and be refused.
@Test func retriesLeaveTheDuePollAlone() {
    var gate = FetchGate(freshness: 4)
    let polled = gate.begin("g1", now: t0)
    #expect(polled)
    gate.end("g1")
    let retry = gate.beginRetry("g1")
    #expect(retry)
    gate.end("g1")
    #expect(gate.lastStarted("g1") == t0)
    let due = gate.begin("g1", now: t0.addingTimeInterval(5))
    #expect(due)
}

// MARK: - TrackedFeedPolicy

@Test func feedIsBehindWhenTheScoreboardNamesAPlayItLacks() throws {
    let detail = try mappedDetail()
    let newest = try #require(detail.drives.first?.plays.last?.id)
    #expect(TrackedFeedPolicy.isBehind(latestPlayID: "not-in-feed", held: detail))
    #expect(!TrackedFeedPolicy.isBehind(latestPlayID: newest, held: detail))
    // Nothing held yet counts as behind, but only once there is a play to be behind.
    #expect(TrackedFeedPolicy.isBehind(latestPlayID: "1", held: nil))
    #expect(!TrackedFeedPolicy.isBehind(latestPlayID: nil, held: nil))
    #expect(!TrackedFeedPolicy.isBehind(latestPlayID: "", held: detail))
}

@Test func trackedGameWithNoFeedYetIsFetched() throws {
    #expect(TrackedFeedPolicy.shouldFetch(latestPlayID: "1", held: nil, lastFetched: nil,
                                          maxAge: 60, now: t0))
    // Fetched before but nothing held (the fetch failed): try again.
    #expect(TrackedFeedPolicy.shouldFetch(latestPlayID: "1", held: nil,
                                          lastFetched: t0.addingTimeInterval(-5), maxAge: 60, now: t0))
}

@Test func trackedGameIsSkippedWhileTheFeedHasTheLatestPlay() throws {
    let detail = try mappedDetail()
    let newest = try #require(detail.drives.first?.plays.last?.id)
    #expect(!TrackedFeedPolicy.shouldFetch(latestPlayID: newest, held: detail,
                                           lastFetched: t0.addingTimeInterval(-20), maxAge: 60, now: t0))
}

@Test func trackedGameIsFetchedWhenTheScoreboardIsAhead() throws {
    let detail = try mappedDetail()
    // The scoreboard names a play the held feed does not contain yet.
    #expect(TrackedFeedPolicy.shouldFetch(latestPlayID: "not-in-feed", held: detail,
                                          lastFetched: t0.addingTimeInterval(-6), maxAge: 60, now: t0))
}

@Test func trackedGameIsRefetchedOnceTheFeedIsOld() throws {
    let detail = try mappedDetail()
    let newest = try #require(detail.drives.first?.plays.last?.id)
    // Nothing new on the scoreboard, but a minute has passed: pick up ESPN's edits.
    #expect(TrackedFeedPolicy.shouldFetch(latestPlayID: newest, held: detail,
                                          lastFetched: t0.addingTimeInterval(-61), maxAge: 60, now: t0))
    // Halftime and between quarters the scoreboard may name no play at all.
    #expect(!TrackedFeedPolicy.shouldFetch(latestPlayID: nil, held: detail,
                                           lastFetched: t0.addingTimeInterval(-30), maxAge: 60, now: t0))
}

@Test func detailFindsPlaysInAnyDrive() throws {
    let detail = try mappedDetail()
    let oldest = try #require(detail.drives.last?.plays.first?.id)
    let newest = try #require(detail.drives.first?.plays.last?.id)
    #expect(detail.containsPlay(id: oldest))
    #expect(detail.containsPlay(id: newest))
    #expect(!detail.containsPlay(id: "nope"))
}

// MARK: - BodyFingerprints

@Test func identicalBodyIsRecognised() throws {
    let body = try fixture("summary")
    var fingerprints = BodyFingerprints()
    let url = "https://example.invalid/summary?event=1"
    #expect(!fingerprints.matches(BodyFingerprints.fingerprint(body), for: url))
    fingerprints.remember(BodyFingerprints.fingerprint(body), for: url)
    // A second download of the same bytes, in a separate buffer.
    let again = Data(body)
    #expect(fingerprints.matches(BodyFingerprints.fingerprint(again), for: url))
    // The same body under a different URL is a different question.
    #expect(!fingerprints.matches(BodyFingerprints.fingerprint(again), for: url + "2"))
}

/// `Data.hashValue` only reads the first few dozen bytes; a play feed that differs by one
/// new play near the end must not be mistaken for the last one.
@Test func bodyDifferingOnlyNearTheEndIsNotRecognised() throws {
    let body = try fixture("summary")
    var changed = body
    changed[changed.count - 10] ^= 0x01
    var fingerprints = BodyFingerprints()
    fingerprints.remember(BodyFingerprints.fingerprint(body), for: "u")
    #expect(!fingerprints.matches(BodyFingerprints.fingerprint(changed), for: "u"))
}

// MARK: - PollSchedule

@Test func firstPollIsImmediate() {
    #expect(PollSchedule.delay(lastPoll: nil, interval: 10, now: t0) == 0)
}

@Test func focusChangeWaitsOutTheRestOfTheNewInterval() {
    // Panel opened three seconds after a poll: the open-panel interval is ten seconds.
    let last = t0.addingTimeInterval(-3)
    #expect(PollSchedule.delay(lastPoll: last, interval: 10, now: t0) == 7)
}

@Test func staleDataPollsStraightAway() {
    // Panel opened a minute after the last closed-panel poll.
    let last = t0.addingTimeInterval(-60)
    #expect(PollSchedule.delay(lastPoll: last, interval: 10, now: t0) == 0)
}
