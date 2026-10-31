import Foundation
@testable import SimulCore

@MainActor
func registerReviewNavigationTests() {
    test("keys: j / k step through files and stop at the ends") {
        let paths = ["a", "b", "c"]
        expectEqual(ReviewNavigation.file(from: nil, in: paths, forward: true), "a", "from nowhere: the first")
        expectEqual(ReviewNavigation.file(from: "a", in: paths, forward: true), "b", "next")
        expectEqual(ReviewNavigation.file(from: "b", in: paths, forward: false), "a", "previous")
        expectEqual(ReviewNavigation.file(from: "c", in: paths, forward: true), nil, "past the end")
        expectEqual(ReviewNavigation.file(from: "gone", in: paths, forward: true), "a", "filtered out: start over")
    }

    test("keys: n / p cross files and skip collapsed ones") {
        let files = [(path: "a", hunks: 2), (path: "b", hunks: 0), (path: "c", hunks: 1)]
        let at = { (p: String, h: Int) in ReviewCursor(path: p, hunk: h) }
        expectEqual(ReviewNavigation.hunk(from: nil, in: files, forward: true), at("a", 0), "first hunk")
        expectEqual(ReviewNavigation.hunk(from: at("a", 0), in: files, forward: true), at("a", 1), "same file")
        expectEqual(ReviewNavigation.hunk(from: at("a", 1), in: files, forward: true), at("c", 0), "skips collapsed b")
        expectEqual(ReviewNavigation.hunk(from: at("c", 0), in: files, forward: true), nil, "past the end")
        expectEqual(ReviewNavigation.hunk(from: at("c", 0), in: files, forward: false), at("a", 1), "back across b")
        expectEqual(ReviewNavigation.hunk(from: at("b", -1), in: files, forward: true), at("c", 0), "from a file: its first")
        expectEqual(ReviewNavigation.hunk(from: at("a", -1), in: files, forward: true), at("a", 0), "a file's own first hunk")
        expectEqual(ReviewNavigation.hunk(from: nil, in: files, forward: false), nil, "nowhere to go back to")
    }

    test("suggestion: a block round-trips and splits from the prose") {
        let block = Suggestion.block(["let a = 1", "", "let b = 2"])
        expectEqual(block, "```suggestion\nlet a = 1\n\nlet b = 2\n```", "fenced")
        expectEqual(Suggestion.parts("Rename it:\n" + block + "\nthanks"),
                    [.text("Rename it:"), .suggestion(["let a = 1", "", "let b = 2"]), .text("thanks")], "parts")
        expectEqual(Suggestion.parts("```suggestion\n```"), [.suggestion([])], "empty: delete the lines")
        expectEqual(Suggestion.parts("```suggestion\nx"), [.suggestion(["x"])], "unclosed runs to the end")
        expectEqual(Suggestion.parts("plain\n```swift\ncode\n```"), [.text("plain\n```swift\ncode\n```")], "other fences are prose")
        expect(Suggestion.contains(block) && !Suggestion.contains("plain"), "contains")
        expectEqual(Suggestion.parts("Hi\r\n```suggestion\r\nx\r\n```\r\n"), [.text("Hi"), .suggestion(["x"])], "CRLF")
        expectEqual(Suggestion.parts("````suggestion\na\n```\nb\n````\nafter"),
                    [.suggestion(["a", "```", "b"]), .text("after")], "4 backticks close on 4, not 3")
        let fenced = Suggestion.block(["```swift", "x"])
        expect(fenced.hasPrefix("````suggestion\n") && fenced.hasSuffix("\n````"), "a ``` in the lines: a longer fence")
        expectEqual(Suggestion.parts(fenced), [.suggestion(["```swift", "x"])], "round trip")
    }
}
