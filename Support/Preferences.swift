import Foundation

/// User preferences (Settings window). Keys live here so views and model
/// agree; values are plain UserDefaults.
enum Preferences {
    enum Key {
        /// Highlighted agent on the new-session page (also the last one used).
        static let defaultAgent = "newSession.lastAgent"
        static let directoryMode = "newSession.directoryMode"
        static let customDirectory = "newSession.customDirectory"
        static let skipPermissions = "newSession.skipPermissions"
        static let confirmClose = "sessions.confirmClose"
        static let sidebarVisible = "sidebar.visible"
        static let showLimits = "sidebar.showLimits"
        static let showMenuBarItem = "menuBar.show"
        static let showDetails = "sidebar.showDetails"

        static func extraArguments(_ agentID: String) -> String { "agent.\(agentID).extraArguments" }
    }

    /// Where a new session starts.
    enum DirectoryMode: String, CaseIterable {
        case currentSession, home, custom
    }

    static func extraArguments(for agentID: String, defaults: UserDefaults = .standard) -> [String] {
        ShellWords.split(defaults.string(forKey: Key.extraArguments(agentID)) ?? "")
    }

    /// Bool preference that defaults to true when never set.
    static func flag(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

/// Splits a command-line fragment like a shell would: whitespace separates,
/// '…' and "…" group, backslash escapes the next character.
enum ShellWords {
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for char in text {
            if escaped {
                current.append(char); escaped = false; inWord = true
            } else if char == "\\", quote != "'" {
                escaped = true
            } else if let open = quote {
                if char == open { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char; inWord = true
            } else if char.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(char); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
