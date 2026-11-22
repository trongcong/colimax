import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class ScheduleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = TestSupport.tempRoot.appendingPathComponent("colimax-sc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func schedule(keep: Int = 2, target: BackupSchedule.Target = .volume(name: "pgdata")) -> BackupSchedule {
        BackupSchedule(profile: "default", target: target, interval: .daily, directory: dir.path, keep: keep)
    }

    func testDueLogicAndRetryAfterFailure() {
        var s = schedule()
        let now = Date()
        XCTAssertTrue(s.isDue(at: now), "never run: due immediately (including catch-up runs)")
        s.lastRun = now.addingTimeInterval(-3600)
        XCTAssertFalse(s.isDue(at: now))
        s.lastError = "VM stopped"
        XCTAssertTrue(s.isDue(at: now), "after a failure: retry after 15 minutes")
        s.lastRun = now.addingTimeInterval(-60)
        XCTAssertFalse(s.isDue(at: now))
        s.enabled = false
        s.lastRun = nil
        XCTAssertFalse(s.isDue(at: now))
    }

    func testFileNameAndOwnership() {
        let s = schedule(target: .database(container: "db-1", engine: "postgres"))
        let name = s.fileName(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(name, "db-1-19700101-000000.sql")
        XCTAssertTrue(s.ownsFileName(name))
        XCTAssertFalse(s.ownsFileName("db-1-manual.sql"))
        XCTAssertFalse(s.ownsFileName("db-1-19700101-000000.sql.manifest.json"))
        XCTAssertFalse(s.ownsFileName("db-10-19700101-000000.sql"), "different source sharing the same prefix")
    }

    func testValidity() {
        XCTAssertTrue(schedule().isValid)
        XCTAssertFalse(schedule(keep: 0).isValid)
        XCTAssertFalse(schedule(target: .volume(name: "../x")).isValid)
        XCTAssertFalse(schedule(target: .database(container: "db", engine: "oracle")).isValid)
        var relative = schedule()
        relative.directory = "backups"
        XCTAssertFalse(relative.isValid)
    }

    func testCodableRoundTrip() throws {
        let s = schedule(target: .database(container: "db", engine: "mysql"))
        let decoded = try JSONDecoder().decode(BackupSchedule.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }

    private func makeBackup(_ s: BackupSchedule, age: TimeInterval, source: String? = nil, name: String? = nil) throws -> URL {
        let date = Date().addingTimeInterval(-age)
        let fileName = name ?? s.fileName(at: date)
        let file = dir.appendingPathComponent(fileName)
        try Data("x".utf8).write(to: file)
        try BackupManifest(kind: s.target.manifestKind, source: source ?? s.target.source, image: nil, createdAt: date,
                           fileName: fileName, size: 1, sha256: "00").write(for: file)
        return file
    }

    func testRetentionKeepsNewestAndNeverTouchesForeignFiles() throws {
        let s = schedule(keep: 2)
        let newest = try makeBackup(s, age: 10)
        let middle = try makeBackup(s, age: 100)
        let old = try makeBackup(s, age: 1000)
        let oldest = try makeBackup(s, age: 10000)
        // Manually named files and files from other sources must not be deleted.
        let manual = try makeBackup(s, age: 99999, name: "pgdata-manual.tar")
        let foreign = dir.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: foreign)
        let noManifest = dir.appendingPathComponent(s.fileName(at: Date().addingTimeInterval(-50000)))
        try Data("x".utf8).write(to: noManifest)

        let removed = BackupRetention.apply(in: dir, schedule: s)
        XCTAssertEqual(removed, 2)
        let fm = FileManager.default
        for kept in [newest, middle, manual, foreign, noManifest] { XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.lastPathComponent) }
        for gone in [old, oldest] {
            XCTAssertFalse(fm.fileExists(atPath: gone.path))
            XCTAssertFalse(fm.fileExists(atPath: BackupManifest.url(for: gone).path))
        }
    }

    func testRetentionIgnoresManifestFromOtherSource() throws {
        let s = schedule(keep: 1)
        _ = try makeBackup(s, age: 10)
        let mismatched = try makeBackup(s, age: 1000, source: "other")
        BackupRetention.apply(in: dir, schedule: s)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mismatched.path))
    }

    /// Manifests store timestamps to the second; when they tie (several runs in the same second),
    /// retention falls back to the file name and still deletes the oldest backup.
    func testRetentionTieBreaksByFileName() throws {
        let s = schedule(keep: 2)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var files: [URL] = []
        for offset in 0..<3 {
            let name = s.fileName(at: base.addingTimeInterval(TimeInterval(offset * 60)))
            let file = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            try BackupManifest(kind: .volume, source: "pgdata", image: nil, createdAt: base, fileName: name, size: 1, sha256: "00").write(for: file)
            files.append(file)
        }
        XCTAssertEqual(BackupRetention.apply(in: dir, schedule: s), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[2].path))
    }
}
