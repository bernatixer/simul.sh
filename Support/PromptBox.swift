import Foundation

/// Reads Claude Code's input box off the screen, to press Return after a
/// paste only when the user hadn't typed anything. Errs to "not empty":
/// anything it doesn't recognise (another agent, a menu, a placeholder,
/// text) leaves the paste waiting.
enum PromptBox {
    /// The last box on screen is a prompt line (`>` or `❯` and nothing else)
    /// between two rules, with at most a few hint or status lines below it.
    static func isEmpty(_ screen: String) -> Bool { input(screen) == "" }

    /// The box holds only Claude Code's collapsed paste (`> [Pasted text #N +M
    /// lines]`): nothing typed since, no prompt in its place. Checked again
    /// right before the Return.
    static func holdsOnlyPaste(_ screen: String) -> Bool {
        input(screen)?.range(of: #"^\[Pasted text #\d+ \+\d+ lines\]$"#, options: .regularExpression) != nil
    }

    /// Empty, or showing Claude Code's own hint (`Try "…"`, drawn faint, which
    /// screen text can't tell from typing). For prompts Simul sends itself:
    /// their Return is checked again with `holds` before it's pressed.
    static func isEmptyOrHint(_ screen: String) -> Bool {
        guard let typed = input(screen) else { return false }
        return typed.isEmpty || typed.range(of: #"^Try "[^"]*"$"#, options: .regularExpression) != nil
    }

    /// The last box on screen is a prompt line, empty or not.
    static func hasBox(_ screen: String) -> Bool { input(screen) != nil }

    /// The last box holds exactly `text`: inline (one line or wrapped onto
    /// several), or collapsed as `[Pasted text #N +M lines]`.
    static func holds(_ text: String, _ screen: String) -> Bool {
        if holdsOnlyPaste(screen) { return true }
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let bottom = lines.lastIndex(where: isRule), let top = lines[..<bottom].lastIndex(where: isRule),
              bottom - top >= 2, lines[(bottom + 1)...].count(where: { !$0.isEmpty }) <= 4 else { return false }
        var content = lines[(top + 1)..<bottom].joined(separator: " ")
        guard content.first == ">" || content.first == "❯" else { return false }
        content.removeFirst()
        func squeezed(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return squeezed(content) == squeezed(text)
    }

    /// What's typed in the last box on screen (after `>` or `❯`, trimmed);
    /// nil if it isn't such a box between two rules with at most a few hint
    /// or status lines below it.
    private static func input(_ screen: String) -> String? {
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let bottom = lines.lastIndex(where: isRule), bottom >= 2, isRule(lines[bottom - 2]),
              lines[(bottom + 1)...].count(where: { !$0.isEmpty }) <= 4 else { return nil }
        var prompt = Substring(lines[bottom - 1])
        if prompt.first == "│", prompt.last == "│", prompt.count >= 2 { prompt = prompt.dropFirst().dropLast() }
        let bare = prompt.trimmingCharacters(in: .whitespaces)
        guard bare.first == ">" || bare.first == "❯" else { return nil }
        return bare.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// A horizontal box edge: only line-drawing characters, and long.
    private static func isRule(_ line: String) -> Bool {
        line.count >= 10 && line.allSatisfy { "─━╭╮╰╯".contains($0) }
    }
}
