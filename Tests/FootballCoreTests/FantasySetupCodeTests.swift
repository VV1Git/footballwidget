import Foundation
import Testing
@testable import FootballCore

/// Produced by actually running the browser snippet (in Node, with a mocked
/// `document.cookie`), not hand-written — so this test fails if the Swift parser and
/// the JavaScript ever stop agreeing.
private let codeFromBrowser =
    "FW1.eyJsIjoiOTg3NjU0IiwicyI6IntBQkNELTEyMzQtRUZHSH0iLCJlIjoiQUVCeHl6JTJGYWJjJTNEJTNEIn0="

@Test func parsesTheCodeTheBrowserSnippetProduces() throws {
    let code = try #require(FantasySetupCodeParser.parse(codeFromBrowser))
    #expect(code.leagueID == "987654")
    #expect(code.swid == "{ABCD-1234-EFGH}")
    #expect(code.espnS2 == "AEBxyz%2Fabc%3D%3D")
}

@Test func roundTripsThroughOurOwnEncoder() throws {
    let original = FantasySetupCode(leagueID: "123", swid: "{S-1}", espnS2: "AEB%2Fx")
    let parsed = try #require(FantasySetupCodeParser.parse(FantasySetupCodeParser.encode(original)))
    #expect(parsed == original)
}

/// The code travels via a clipboard and a console, so it arrives with all sorts of
/// decoration around it.
@Test func toleratesHowPeopleActuallyPaste() throws {
    let variants = [
        "  \(codeFromBrowser)  ",
        "\n\(codeFromBrowser)\n",
        "\"\(codeFromBrowser)\"",
        "'\(codeFromBrowser)'",
        codeFromBrowser.replacingOccurrences(of: "=", with: ""),      // padding stripped
    ]
    for variant in variants {
        let parsed = FantasySetupCodeParser.parse(variant)
        #expect(parsed?.leagueID == "987654", "failed on: \(variant.prefix(12))…")
    }
}

/// A console can hard-wrap a long line when it is copied out of the log.
@Test func rejoinsALineTheConsoleWrapped() throws {
    var wrapped = codeFromBrowser
    let middle = wrapped.index(wrapped.startIndex, offsetBy: 30)
    wrapped.insert(contentsOf: "\n  ", at: middle)
    let parsed = try #require(FantasySetupCodeParser.parse(wrapped))
    #expect(parsed.swid == "{ABCD-1234-EFGH}")
}

@Test func rejectsAnythingThatIsNotASetupCode() {
    for junk in ["", "hello", "FW1.", "FW2.abcd", "not a code at all",
                 "https://fantasy.espn.com/football/team?leagueId=1"] {
        #expect(FantasySetupCodeParser.parse(junk) == nil, "should reject: \(junk)")
    }
}

/// A code with no cookies in it is useless, so it must not be treated as a success.
@Test func rejectsACodeMissingItsCookies() {
    let empty = FantasySetupCodeParser.encode(
        FantasySetupCode(leagueID: "123", swid: "", espnS2: "")
    )
    #expect(FantasySetupCodeParser.parse(empty) == nil)
}

/// Running it somewhere without a league id in the URL still yields usable cookies —
/// the user just has to supply the league themselves.
@Test func acceptsACodeWithNoLeagueID() throws {
    let code = FantasySetupCodeParser.encode(
        FantasySetupCode(leagueID: "", swid: "{S}", espnS2: "abc")
    )
    let parsed = try #require(FantasySetupCodeParser.parse(code))
    #expect(parsed.leagueID.isEmpty)
    #expect(parsed.isUsable)
}

@Test func theBrowserCommandIsASingleLine() {
    let command = FantasySetupCodeParser.browserCommand
    #expect(!command.contains("\n"), "a console runs on newline, so this must be one line")
    #expect(command.contains("espn_s2"))
    #expect(command.contains("SWID"))
    #expect(command.hasPrefix("(()=>{"))
}
