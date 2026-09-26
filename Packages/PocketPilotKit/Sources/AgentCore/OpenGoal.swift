import Foundation

/// Detects goals that are only "open this app, then stop" so the agent can finish
/// without asking the model — models have ignored the App: line and kept tapping.
enum OpenGoal {
    /// The mentioned app that is currently frontmost, if any.
    static func mentionedFrontmost(app: FrontmostApp?, mentioned: [String]) -> String? {
        guard let app else { return nil }
        return mentioned.first { $0.caseInsensitiveCompare(app.briefName) == .orderedSame }
    }

    /// True when `goal` is open/`app` plus optional finish / don't-change wording.
    static func isPureOpen(_ goal: String, app: String) -> Bool {
        leftoverWords(in: goal, app: app).isEmpty
    }

    static func leftoverWords(in goal: String, app: String) -> [String] {
        var text = " \(goal.lowercased()) "
        for phrase in noisePhrases {
            text = text.replacingOccurrences(of: phrase, with: " ")
        }
        let letters = text.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
        let tokens = String(letters).split(whereSeparator: \.isWhitespace).map(String.init)
        let appWords = app.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let drop = Set(["open", "the", "app"] + appWords)
        return tokens.filter { !drop.contains($0) }
    }

    private static let noisePhrases = [
        "do not change anything", "don't change anything", "do not change", "don't change",
        "then finish", "then stop", "then done", "and finish", "and stop",
        "read-only", "read only", "please", "just", "for me",
    ].sorted { $0.count > $1.count }
}
