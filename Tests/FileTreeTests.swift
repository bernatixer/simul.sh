import Foundation
@testable import SimulCore

@MainActor
func registerFileTreeTests() {
    test("file tree: folders first, single-child folders compacted, files in tree order") {
        let rows = FileTree.rows(["z.md", "app/services/ai/b.py", "app/services/ai/a.py", "app/api/x.py", "a.md"])
        expectEqual(rows.map(\.name), ["app", "api", "x.py", "services/ai", "a.py", "b.py", "a.md", "z.md"], "rows")
        expectEqual(rows.map(\.depth), [0, 1, 2, 1, 2, 2, 0, 0], "depths")
        expectEqual(rows[3].path, "app/services/ai", "compacted folder's path")
        expectEqual(FileTree.order(["b/x", "a.md", "b/a"]), ["b/a", "b/x", "a.md"], "order")
    }
}

@MainActor
func registerDiffGapTests() {
    test("diff gaps: between hunks, before the first, after the last once the file's length is known") {
        let diff = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -5,3 +5,4 @@ a
         x
        +y
         z
         w
        @@ -40,2 +41,1 @@ b
         q
        -r
        """
        let hunks = UnifiedDiff.parse(diff)[0].hunks
        let open = DiffGap.gaps(hunks, lineCount: nil)
        expectEqual(open.map(\.first), [1, 9, 42], "firsts")
        expectEqual(open.map(\.size), [4, 32, 0], "sizes, the last unknown")
        expectEqual(open.map(\.offset), [0, -1, 0], "old = new + offset")
        expectEqual(DiffGap.gaps(hunks, lineCount: 50).last?.size, 9, "to the end")
    }
}
