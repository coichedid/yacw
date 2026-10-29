import Foundation

/// URLs of source C, entered by the user in Settings (never bundled or versioned). The account endpoints contain the
/// organization id, which is personal, so the app only accepts what the user pastes and checks its shape.
public enum EndpointURL {
    public static let host = "claude.ai"
    public static let pathPrefix = "/api/organizations/"

    /// https, host exactly `claude.ai`, path under `/api/organizations/`; anything else is rejected.
    public static func validate(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), u.scheme == "https", u.host == host, u.user == nil, u.port == nil,
              u.path.hasPrefix(pathPrefix), u.path.count > pathPrefix.count else { return nil }
        return u
    }

    /// Observed shape of the two calls: `<prefix><org>/usage` and `<prefix><org>/prepaid/credits`. When only the usage URL
    /// is set, the credits URL is derived from it (hypothesis for other accounts; the user can always override it).
    public static func derivedCreditsURL(fromUsage usage: URL) -> URL? {
        guard usage.path.hasSuffix("/usage") else { return nil }
        var c = URLComponents(url: usage, resolvingAgainstBaseURL: false)
        c?.path = String(usage.path.dropLast("/usage".count)) + "/prepaid/credits"
        c?.query = nil
        return c?.url
    }
}
