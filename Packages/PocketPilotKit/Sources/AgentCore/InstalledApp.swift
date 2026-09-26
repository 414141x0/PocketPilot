/// An app on the device that the agent can open by name.
import Foundation

public struct InstalledApp: Sendable, Hashable, Decodable {
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
    }
}

/// The application currently owning the device's foreground UI.
public struct FrontmostApp: Sendable, Hashable, Decodable {
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }

    /// The name shown in the brief: SpringBoard is the Home Screen.
    public var briefName: String {
        bundleID == "com.apple.springboard" ? "Home Screen" : name
    }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
    }
}

extension [InstalledApp] {
    /// Names of apps that appear as whole words in `text`, longest first so "App Store" wins over "App".
    func named(in text: String) -> [String] {
        let words = text.lowercased()
        return map(\.name)
            .filter { name in
                name.count >= 3 && words.range(of: "\\b\(NSRegularExpression.escapedPattern(for: name.lowercased()))\\b", options: .regularExpression) != nil
            }
            .sorted { $0.count > $1.count }
    }

    /// The bundle identifier for `query`, which may be a display name or a bundle identifier.
    ///
    /// Tries, in order: an exact bundle identifier, a case-insensitive name, then a name that
    /// uniquely starts with or contains the query. With no list to check, the query passes through
    /// as a bundle identifier.
    func bundleID(for query: String) throws(ResolutionError) -> String {
        guard !isEmpty else { return query }
        let needle = query.lowercased()
        if let app = first(where: { $0.bundleID.lowercased() == needle || $0.name.lowercased() == needle }) {
            return app.bundleID
        }
        for matches in [filter { $0.name.lowercased().hasPrefix(needle) }, filter { $0.name.lowercased().contains(needle) }] {
            if matches.count == 1 { return matches[0].bundleID }
        }
        let similar: [String] = filter { $0.name.lowercased().contains(needle.prefix(3)) }.prefix(5).map(\.name)
        throw .unknownApp(query, similar: similar)
    }
}
