import Foundation

/// Everything needed to connect a league, carried in one paste-able string.
public struct FantasySetupCode: Sendable, Equatable {
    public var leagueID: String
    public var swid: String
    public var espnS2: String

    public init(leagueID: String, swid: String, espnS2: String) {
        self.leagueID = leagueID
        self.swid = swid
        self.espnS2 = espnS2
    }

    public var isUsable: Bool { !swid.isEmpty && !espnS2.isEmpty }
}

/// Encodes and decodes the setup code produced by the browser snippet.
///
/// Digging two cookies out of DevTools by hand is the worst part of connecting a
/// league, so the app hands over a one-line command instead: run it on your ESPN
/// league page and it prints a single code carrying the league id and both cookies.
///
/// The payload is base64 rather than delimited text because `espn_s2` is a long
/// URL-encoded blob and SWID is wrapped in braces — both liable to contain whatever
/// separator you pick.
public enum FantasySetupCodeParser {

    public static let prefix = "FW1."

    private struct Payload: Codable {
        var l: String?   // league id
        var s: String?   // SWID
        var e: String?   // espn_s2
    }

    public static func parse(_ raw: String) -> FantasySetupCode? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // People paste with surrounding quotes surprisingly often.
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard text.hasPrefix(prefix) else { return nil }

        var encoded = String(text.dropFirst(prefix.count))
        // A console can wrap a long line; rejoin it before decoding.
        encoded.removeAll { $0.isWhitespace }
        guard !encoded.isEmpty else { return nil }

        // Tolerate base64url and missing padding, since the code travels via a
        // clipboard and a console.
        encoded = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if encoded.count % 4 != 0 {
            encoded += String(repeating: "=", count: 4 - (encoded.count % 4))
        }

        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }

        let code = FantasySetupCode(
            leagueID: (payload.l ?? "").trimmingCharacters(in: .whitespaces),
            swid: (payload.s ?? "").trimmingCharacters(in: .whitespaces),
            espnS2: (payload.e ?? "").trimmingCharacters(in: .whitespaces)
        )
        return code.isUsable ? code : nil
    }

    public static func encode(_ code: FantasySetupCode) -> String {
        let payload = Payload(l: code.leagueID, s: code.swid, e: code.espnS2)
        guard let data = try? JSONEncoder().encode(payload) else { return prefix }
        return prefix + data.base64EncodedString()
    }

    /// The one-liner the user runs in their browser's console on their ESPN league
    /// page. Kept on a single line so it survives being pasted into a console that
    /// executes on newline.
    public static var browserCommand: String {
        """
        (()=>{const c={};document.cookie.split('; ').forEach(p=>{const i=p.indexOf('=');if(i>0)c[p.slice(0,i)]=p.slice(i+1)});const e=c.espn_s2||c.ESPN_S2||'';const s=c.SWID||'';const m=location.href.match(/leagueId=(\\d+)/i);if(!e||!s){console.log('%cCould not read your ESPN cookies here. Sign in at fantasy.espn.com, open YOUR league page, and run this again.','color:#c00;font-weight:bold');return}const code='FW1.'+btoa(unescape(encodeURIComponent(JSON.stringify({l:m?m[1]:'',s:s,e:e}))));try{copy(code);console.log('%cCopied. Paste it into Football \\u2192 Settings \\u2192 Fantasy.','color:#0a0;font-weight:bold')}catch(_){console.log('%cCopy the line below into Football \\u2192 Settings \\u2192 Fantasy.','color:#0a0;font-weight:bold')}console.log(code)})()
        """
    }
}
