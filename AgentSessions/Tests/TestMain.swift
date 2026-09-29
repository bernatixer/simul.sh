import Foundation

// Minimal test harness: no XCTest, no swift-testing, no Xcode needed.
// Tests are registered as functions and run sequentially from main.

@MainActor var testFailures = 0
@MainActor var testCount = 0

@MainActor
func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    testCount += 1
    if !condition() {
        testFailures += 1
        print("✘ \(file):\(line) — \(message)")
    }
}

@MainActor
func expectEqual<T: Equatable>(
    _ a: @autoclosure () -> T,
    _ b: @autoclosure () -> T,
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line
) {
    testCount += 1
    if a() != b() {
        testFailures += 1
        print("✘ \(file):\(line) — \(message)")
    }
}

@MainActor
func expectThrows(
    _ message: String,
    file: StaticString = #fileID,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    testCount += 1
    do {
        try await body()
        testFailures += 1
        print("✘ \(file):\(line) — \(message)")
    } catch {
        // expected
    }
}

struct TestCase {
    let name: String
    let run: () async throws -> Void
}

@MainActor var allTests: [TestCase] = []

@MainActor
func test(_ name: String, _ run: @escaping () async throws -> Void) {
    allTests.append(TestCase(name: name, run: run))
}

@main
struct TestMain {
    @MainActor
    static func main() async {
        registerStoreTests()
        registerTmuxTests()
        for testCase in allTests {
            let started = Date()
            do {
                try await testCase.run()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("✔ \(testCase.name) (\(ms)ms)")
            } catch {
                testFailures += 1
                print("✘ \(testCase.name) threw: \(error)")
            }
        }
        print("")
        print("\(allTests.count - min(testFailures, allTests.count))/\(allTests.count) tests passed, \(testFailures) assertions failed")
        if testFailures > 0 {
            exit(1)
        }
    }
}
