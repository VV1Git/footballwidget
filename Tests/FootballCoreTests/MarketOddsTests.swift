import Foundation
import Testing
@testable import FootballCore

/// Kalshi's events response, recorded live on 2026-10-04 during KC @ LV.
private func recordedEvents() throws -> KalshiEventsDTO {
    let located = Bundle.module.url(forResource: "kalshi-events", withExtension: "json",
                                    subdirectory: "Fixtures")
    let url = try #require(located)
    return try JSONDecoder().decode(KalshiEventsDTO.self, from: Data(contentsOf: url))
}

private func game(away: String, home: String, kickoff: String) -> Game {
    let formatter = ISO8601DateFormatter()
    return Game(id: "g", shortName: "\(away) @ \(home)", kickoff: formatter.date(from: kickoff),
                phase: .live, statusDetail: "", period: 2, displayClock: "5:00",
                home: TeamSide(id: "h", abbreviation: home, displayName: home, shortName: home, score: 7),
                away: TeamSide(id: "a", abbreviation: away, displayName: away, shortName: away, score: 7))
}

@Test func kalshiOddsNameTheFavourite() throws {
    let odds = try #require(KalshiOdds.odds(for: game(away: "KC", home: "LV", kickoff: "2026-10-04T20:25:00Z"),
                                            in: recordedEvents()))
    // KC bid 0.89 / ask 0.90, LV 0.10 / 0.11: 0.895 against 0.105.
    #expect(odds.teamAbbreviation == "KC")
    #expect(odds.label == "KC 90%")
    #expect(odds.source == "Kalshi")
}

/// A Sunday night game kicks off after midnight UTC; the ticker carries the Eastern date.
@Test func kalshiTickerDateIsEastern() {
    let formatter = ISO8601DateFormatter()
    let sundayNight = formatter.date(from: "2026-10-05T00:20:00Z")!
    #expect(KalshiOdds.tickerDate(sundayNight) == "26OCT04")
}

@Test func kalshiOddsNeedTheRightDateAndTeams() throws {
    let events = try recordedEvents()
    #expect(KalshiOdds.odds(for: game(away: "KC", home: "LV", kickoff: "2026-12-20T20:25:00Z"), in: events) == nil)
    #expect(KalshiOdds.odds(for: game(away: "KC", home: "DEN", kickoff: "2026-10-04T20:25:00Z"), in: events) == nil)
}

@Test func kalshiCodesDifferInTwoPlaces() {
    #expect(KalshiOdds.kalshiCode("JAX") == "JAC")
    #expect(KalshiOdds.kalshiCode("WSH") == "WAS")
    #expect(KalshiOdds.kalshiCode("KC") == "KC")
}

/// A wide spread means the quote is stale or thin; the last trade says more.
@Test func kalshiPriceFallsBackToTheLastTrade() {
    let tight = KalshiMarketDTO(ticker: nil, status: nil, yesBid: "0.60", yesAsk: "0.62", lastPrice: "0.50")
    let wide = KalshiMarketDTO(ticker: nil, status: nil, yesBid: "0.30", yesAsk: "0.70", lastPrice: "0.55")
    #expect(KalshiOdds.price(tight) == 0.61)
    #expect(KalshiOdds.price(wide) == 0.55)
}
