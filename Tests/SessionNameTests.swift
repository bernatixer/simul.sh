import Foundation
@testable import SimulCore

@MainActor
func registerSessionNameTests() {
    test("Session names: supplied names survive provider and prompt suggestions") {
        var session = Session(title: "My chosen name", workingDirectory: "/repo", agentID: "claude")
        expect(!session.useTitle("Another name", origin: .provider), "a provider cannot replace a supplied name")
        expect(!session.useTitle("First prompt", origin: .prompt), "a prompt cannot replace a supplied name")
        expectEqual(session.title, "My chosen name", "the supplied name remains unchanged")
    }
    test("Session names: first prompt is stable and a manual rename always wins") {
        var session = Session(title: "", workingDirectory: "/repo", agentID: "codex")
        expect(session.useTitle("  Fix the\n chat sidebar  ", origin: .prompt), "the first prompt names an unnamed session")
        expectEqual(session.title, "Fix the chat sidebar", "whitespace is collapsed")
        expect(!session.useTitle("A later prompt", origin: .prompt), "later prompts do not keep renaming the row")
        expect(session.useTitle("Refine chat sidebar", origin: .provider), "a provider title can improve the prompt fallback")
        expect(session.useTitle(session.title, origin: .provided), "confirming the same name records manual ownership")
        expect(!session.useTitle("Late provider title", origin: .provider), "late metadata cannot undo a rename")
        expectEqual(session.title, "Refine chat sidebar", "the manual name stays")
    }
    test("Session names: automatic names are bounded without splitting characters") {
        var session = Session(title: "", workingDirectory: "/repo", agentID: "claude")
        expect(!session.useTitle(" \n\t ", origin: .prompt), "an empty suggestion leaves the session unnamed")
        expect(session.useTitle(String(repeating: "🧑🏽‍💻", count: 200), origin: .prompt), "a long prompt can still name the session")
        expectEqual(session.title.count, 70, "the name stays within the row's bounded title budget")
        expect(session.title.hasSuffix("…"), "truncation is visible")
    }
    test("Session names: older records preserve their names conservatively") {
        let session = Session(title: "repo", workingDirectory: "/repo", agentID: "claude")
        let data = try JSONEncoder().encode(session)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "titleOrigin")
        var loaded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        expect(!loaded.useTitle("New title", origin: .provider), "missing provenance never authorizes overwriting an old name")
        expectEqual(loaded.title, "repo", "even a name matching the directory may have been chosen manually")
        var automatic = Session(title: "", workingDirectory: "/repo", agentID: "codex")
        _ = automatic.useTitle("First prompt", origin: .prompt)
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(automatic))
        expectEqual(restored.titleOrigin, .prompt, "automatic provenance survives saving and reloading")
    }
}
