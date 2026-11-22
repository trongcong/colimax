import Foundation

enum TestSupport {
    /// Temporary directory for tests: prefers $TMPDIR (a sandbox may block the default temporaryDirectory).
    static var tempRoot: URL {
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            return URL(fileURLWithPath: tmp, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }
}
