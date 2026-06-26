import Foundation

// Tiny test harness: every test is a closure. Exit code = number of failures.
// Built as an executable so it runs without XCTest/Testing frameworks. Discover by
// scanning the `tests` array. Add a new test → append a (name, closure) entry.

enum TestFailure: Error, CustomStringConvertible {
    case expectation(String)
    var description: String {
        if case .expectation(let s) = self { return s }
        return "failure"
    }
}

// Lightweight assertion helpers used by the test bodies in other files.
func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !condition() {
        throw TestFailure.expectation("\(file):\(line): \(message())")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        throw TestFailure.expectation("\(file):\(line): \(message()) — got \(a) ≠ expected \(b)")
    }
}

func expectClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    if abs(a - b) > tolerance {
        throw TestFailure.expectation("\(file):\(line): \(message()) — \(a) not within \(tolerance) of \(b)")
    }
}

func expectClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 1e-9, _ message: @autoclosure () -> String = "", file: StaticString = #file, line: UInt = #line) throws {
    if abs(a - b) > tolerance {
        throw TestFailure.expectation("\(file):\(line): \(message()) — \(a) not within \(tolerance) of \(b)")
    }
}

// Registry. Files add via append(...).
var tests: [(name: String, run: () throws -> Void)] = []

// Populate from each test file.
registerLineweightTests()
registerThicknessTests()
registerWidePolylineTests()
registerSolidTests()
registerStatikFixtureTests()
registerInspectStatik()

var failures: [(String, Error)] = []
for t in tests {
    do {
        try t.run()
        print("PASS  \(t.name)")
    } catch {
        print("FAIL  \(t.name)  — \(error)")
        failures.append((t.name, error))
    }
}

print("")
print("\(tests.count - failures.count) / \(tests.count) tests passed")
exit(failures.isEmpty ? 0 : 1)
