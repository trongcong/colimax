import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class ShellTests: XCTestCase {
    func testRunHappyPath() async throws {
        let result = try await Shell.run("echo", ["hello", "world"])
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.stdout.trimmed, "hello world")
    }

    func testArgumentsAreNotInterpretedByShell() async throws {
        // Shell metacharacters in arguments must pass through verbatim, never be interpreted.
        let result = try await Shell.run("echo", ["$(whoami); rm -rf /tmp/x"])
        XCTAssertEqual(result.stdout.trimmed, "$(whoami); rm -rf /tmp/x")
    }

    func testNonZeroExit() async throws {
        let result = try await Shell.run("false", [])
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.status, 1)
    }

    func testNotFound() async {
        do {
            _ = try await Shell.run("definitely-not-a-command-colimax", [])
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? ShellError, .notFound("definitely-not-a-command-colimax"))
        }
    }

    func testWhichRejectsPaths() {
        XCTAssertNil(Shell.which("../bin/sh"))
        XCTAssertNil(Shell.which("/bin/sh"))
        XCTAssertNil(Shell.which(""))
        XCTAssertNotNil(Shell.which("sh"))
    }

    func testTimeoutTerminatesProcess() async {
        let start = Date()
        do {
            _ = try await Shell.run("sleep", ["10"], timeout: 0.5)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ShellError, .timedOut("sleep", 0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testCancellationTerminatesProcess() async {
        let start = Date()
        let task = Task { try await Shell.run("sleep", ["10"]) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testCancelledBeforeStartDoesNotHang() async {
        let task = Task {
            try await Task.sleep(for: .milliseconds(50))
            return try await Shell.run("sleep", ["10"])
        }
        task.cancel()
        let result = try? await task.value
        XCTAssertNil(result)
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // > 64 KB pipe buffer.
        let result = try await Shell.run("dd", ["if=/dev/zero", "bs=1000", "count=300"], timeout: 20)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.stdout.utf8.count, 300_000)
    }

    func testConcurrentRuns() async throws {
        let outputs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<24 {
                group.addTask { (i, try await Shell.run("echo", [String(i)]).stdout.trimmed) }
            }
            var collected: [Int: String] = [:]
            for try await (i, out) in group { collected[i] = out }
            return collected
        }
        XCTAssertEqual(outputs.count, 24)
        for (i, out) in outputs { XCTAssertEqual(out, String(i)) }
    }

    func testStreamLines() async throws {
        var lines: [String] = []
        for try await line in Shell.stream("printf", ["a\\nb\\nc"]) { lines.append(line) }
        XCTAssertEqual(lines, ["a", "b", "c"])
    }

    func testStreamFailureCarriesMessage() async {
        do {
            for try await _ in Shell.stream("sh", ["-c", "echo 'level=fatal msg=\"boom\"'; exit 3"]) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ShellError, .failed("boom"))
        }
    }

    func testStreamConsumerCancellationStopsProcess() async {
        let start = Date()
        let task = Task {
            for try await _ in Shell.stream("sleep", ["10"]) {}
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testColimaLogMessage() {
        XCTAssertEqual(ColimaLog.message(of: #"time="x" level=fatal msg="vm not running""#), "vm not running")
        XCTAssertEqual(ColimaLog.errorMessage(in: ["info", "time=1 level=error msg=\"bad\"", ""]), "bad")
    }
}
