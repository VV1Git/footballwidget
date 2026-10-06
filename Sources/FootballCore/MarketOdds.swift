import Foundation

/// A prediction market's read on who wins a game: the favourite and its chance.
public struct WinOdds: Sendable, Hashable {
    /// The favourite, by the scoreboard's abbreviation.
    public var teamAbbreviation: String
    /// 0–1.
    public var probability: Double
    public var source: String

    public init(teamAbbreviation: String, probability: Double, source: String) {
        self.teamAbbreviation = teamAbbreviation
        self.probability = probability
        self.source = source
    }

    /// "KC 85%".
    public var label: String {
        "\(teamAbbreviation) \(Int((probability * 100).rounded()))%"
    }
}

// MARK: - Kalshi

/// `GET /trade-api/v2/events?series_ticker=KXNFLGAME&with_nested_markets=true`: one event
/// per game, one yes/no market per team ("Kansas City wins"), priced in dollars.
public struct KalshiEventsDTO: Decodable, Sendable {
    public var events: [Failable<KalshiEventDTO>]?
}

public struct KalshiEventDTO: Decodable, Sendable {
    /// "KXNFLGAME-26OCT04KCLV": the series, the game's date, then both teams.
    public var eventTicker: String?
    public var markets: [Failable<KalshiMarketDTO>]?

    enum CodingKeys: String, CodingKey {
        case eventTicker = "event_ticker"
        case markets
    }
}

public struct KalshiMarketDTO: Decodable, Sendable {
    /// "KXNFLGAME-26OCT04KCLV-KC": the event, then the team this market pays out on.
    public var ticker: String?
    public var status: String?
    public var yesBid: String?
    public var yesAsk: String?
    public var lastPrice: String?

    enum CodingKeys: String, CodingKey {
        case ticker, status
        case yesBid = "yes_bid_dollars"
        case yesAsk = "yes_ask_dollars"
        case lastPrice = "last_price_dollars"
    }
}

public enum KalshiOdds {

    /// Kalshi's team codes differ from the scoreboard's in two places.
    static func kalshiCode(_ abbreviation: String) -> String {
        ["JAX": "JAC", "WSH": "WAS"][abbreviation] ?? abbreviation
    }

    /// The game's date as Kalshi writes it in tickers ("26OCT04"), in Eastern time —
    /// a Sunday night game kicks off after midnight UTC.
    static func tickerDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyMMMdd"
        return formatter.string(from: date).uppercased()
    }

    /// The market's chance as a fraction: the middle of the bid and ask while the spread
    /// is tight, else the last trade. Nil when neither says anything.
    static func price(_ market: KalshiMarketDTO) -> Double? {
        let bid = market.yesBid.flatMap(Double.init)
        let ask = market.yesAsk.flatMap(Double.init)
        if let bid, let ask, bid > 0, ask > 0, ask - bid <= 0.10 {
            return (bid + ask) / 2
        }
        return market.lastPrice.flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The favourite in `game` and its chance, or nil if Kalshi has no priced market for it.
    ///
    /// Matched on the two teams and the game's date, so next season's rematch — or the
    /// same teams later in the year — is never mistaken for this one.
    public static func odds(for game: Game, in response: KalshiEventsDTO) -> WinOdds? {
        let home = kalshiCode(game.home.abbreviation)
        let away = kalshiCode(game.away.abbreviation)
        let date = game.kickoff.map(tickerDate)

        for event in (response.events ?? []).compacted() {
            guard let ticker = event.eventTicker else { continue }
            if let date, !ticker.contains("-\(date)") { continue }
            let markets = (event.markets ?? []).compacted()
            func market(_ code: String) -> KalshiMarketDTO? {
                markets.first { $0.ticker?.hasSuffix("-\(code)") == true }
            }
            guard let homeMarket = market(home), let awayMarket = market(away) else { continue }

            let homeChance = price(homeMarket)
            let awayChance = price(awayMarket)
            // Each side is its own market; when both are priced they should sum to about
            // one, so take the pair together rather than trusting either alone.
            let chance: Double
            switch (homeChance, awayChance) {
            case let (h?, a?) where h + a > 0: chance = h / (h + a)
            case let (h?, nil): chance = h
            case let (nil, a?): chance = 1 - a
            default: return nil
            }
            let homeFavoured = chance >= 0.5
            return WinOdds(teamAbbreviation: homeFavoured ? game.home.abbreviation : game.away.abbreviation,
                           probability: homeFavoured ? chance : 1 - chance,
                           source: "Kalshi")
        }
        return nil
    }
}
