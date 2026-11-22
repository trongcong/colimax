import XCTest

// Entry point for scripts/run-tests.sh (built with swiftc, not SwiftPM).
// `swift test` does not use this file.
@main
enum TestRunner {
    static func main() {
        let suite = XCTestSuite.default
        suite.run()
        exit(suite.testRun?.hasSucceeded == true ? 0 : 1)
    }
}
