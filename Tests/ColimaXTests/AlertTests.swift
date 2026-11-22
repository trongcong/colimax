import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class AlertTests: XCTestCase {
    private let thresholds = AlertThresholds(cpuPercent: 80, memoryPercent: 90, diskPercent: 85, sustainSamples: 3)

    private func samples(_ cpu: [Double], memory: Int64 = 100, limit: Int64 = 1000, name: String = "web") -> [ResourceSample] {
        cpu.enumerated().map { index, value in
            ResourceSample(date: Date(timeIntervalSince1970: TimeInterval(index * 60)), container: name, cpu: value, memory: memory, memoryLimit: limit)
        }
    }

    func testFiresOnlyAfterSustainedBreach() {
        var evaluator = AlertEvaluator()
        XCTAssertTrue(evaluator.evaluate(["web": samples([90, 95])], thresholds: thresholds).isEmpty, "only 2 samples")
        XCTAssertTrue(evaluator.evaluate(["web": samples([90, 50, 95])], thresholds: thresholds).isEmpty, "not sustained")
        let fired = evaluator.evaluate(["web": samples([85, 90, 95])], thresholds: thresholds)
        XCTAssertEqual(fired.map(\.kind), [.cpu])
        XCTAssertEqual(fired.first?.value, 95)
    }

    func testFiresOnceThenRearmsAfterRecoveryWithHysteresis() {
        var evaluator = AlertEvaluator()
        XCTAssertEqual(evaluator.evaluate(["web": samples([90, 90, 90])], thresholds: thresholds).count, 1)
        XCTAssertEqual(evaluator.evaluate(["web": samples([90, 90, 90, 90])], thresholds: thresholds).count, 0, "no repeat while still breached")
        // 75 ≥ 72 (90% of the threshold): not yet considered recovered.
        _ = evaluator.evaluate(["web": samples([90, 90, 75])], thresholds: thresholds)
        XCTAssertEqual(evaluator.evaluate(["web": samples([90, 90, 90])], thresholds: thresholds).count, 0)
        _ = evaluator.evaluate(["web": samples([90, 90, 10])], thresholds: thresholds)
        XCTAssertEqual(evaluator.evaluate(["web": samples([90, 90, 90])], thresholds: thresholds).count, 1, "re-armed")
    }

    func testMemoryAlertNeedsLimit() {
        var evaluator = AlertEvaluator()
        let high = samples([1, 1, 1], memory: 950, limit: 1000)
        XCTAssertEqual(evaluator.evaluate(["db": high], thresholds: thresholds).map(\.kind), [.memory])
        var other = AlertEvaluator()
        XCTAssertTrue(other.evaluate(["db": samples([1, 1, 1], memory: 950, limit: 0)], thresholds: thresholds).isEmpty)
    }

    func testDiskAlert() {
        var evaluator = AlertEvaluator()
        XCTAssertNil(evaluator.evaluateDisk(profile: "default", percent: 50, threshold: 85))
        XCTAssertEqual(evaluator.evaluateDisk(profile: "default", percent: 90, threshold: 85)?.kind, .disk)
        XCTAssertNil(evaluator.evaluateDisk(profile: "default", percent: 91, threshold: 85))
    }

    func testMetricsHistoryAppendLoadPrune() throws {
        let dir = TestSupport.tempRoot.appendingPathComponent("colimax-mh-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = MetricsHistory.forProfile("default", in: dir)
        let now = Date()
        let old = ResourceSample(date: now.addingTimeInterval(-10 * 24 * 3600), container: "a", cpu: 1, memory: 1, memoryLimit: 2)
        let recent = ResourceSample(date: now.addingTimeInterval(-60), container: "a", cpu: 2, memory: 1, memoryLimit: 2)
        try history.append([old])
        try history.append([recent])
        XCTAssertEqual(history.load(since: .distantPast).count, 2)
        XCTAssertEqual(history.load(since: now.addingTimeInterval(-3600)).map(\.cpu), [2])
        try history.prune(now: now)
        XCTAssertEqual(history.load(since: .distantPast).map(\.cpu), [2])
    }
}
