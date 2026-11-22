import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class ScannerTests: XCTestCase {
    func testParseTrivy() throws {
        let json = """
        {"SchemaVersion":2,"ArtifactName":"nginx:1.25","Results":[
          {"Target":"nginx:1.25 (debian 12.4)","Class":"os-pkgs","Vulnerabilities":[
            {"VulnerabilityID":"CVE-2024-0001","PkgName":"openssl","InstalledVersion":"3.0.11","FixedVersion":"3.0.13","Severity":"CRITICAL","Title":"bad","PrimaryURL":"https://avd.aquasec.com/nvd/cve-2024-0001"},
            {"VulnerabilityID":"CVE-2023-9999","PkgName":"zlib","InstalledVersion":"1.2","FixedVersion":"","Severity":"LOW"}
          ]},
          {"Target":"app","Class":"lang-pkgs"}
        ]}
        """
        let items = try VulnerabilityScanner.parseTrivy(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        let critical = try XCTUnwrap(items.first { $0.cve == "CVE-2024-0001" })
        XCTAssertEqual(critical.severity, .critical)
        XCTAssertEqual(critical.fixed, "3.0.13")
        XCTAssertNil(items.first { $0.cve == "CVE-2023-9999" }?.fixed, "empty FixedVersion means no fix available")
    }

    func testParseTrivyEmptyResults() throws {
        XCTAssertEqual(try VulnerabilityScanner.parseTrivy(Data(#"{"SchemaVersion":2}"#.utf8)), [])
    }

    func testParseSARIF() throws {
        let json = """
        {"version":"2.1.0","runs":[{"tool":{"driver":{"name":"docker scout","rules":[
          {"id":"CVE-2024-1","shortDescription":{"text":"CVE-2024-1"},"helpUri":"https://scout.docker.com/v/CVE-2024-1",
           "properties":{"cvssV3_severity":"HIGH","purls":["pkg:deb/debian/curl@7.88"]}},
          {"id":"CVE-2024-2","properties":{"security-severity":"9.8"}}
        ]}},"results":[
          {"ruleId":"CVE-2024-1","level":"error","message":{"text":"Package  : curl\\nFixed version : 7.88.2"}},
          {"ruleId":"CVE-2024-2","message":{"text":"Package : libx\\nFixed version : not fixed"}}
        ]}]}
        """
        let items = try VulnerabilityScanner.parseSARIF(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        let first = try XCTUnwrap(items.first { $0.cve == "CVE-2024-1" })
        XCTAssertEqual(first.severity, .high)
        XCTAssertEqual(first.package, "pkg:deb/debian/curl@7.88")
        XCTAssertEqual(first.fixed, "7.88.2")
        let second = try XCTUnwrap(items.first { $0.cve == "CVE-2024-2" })
        XCTAssertEqual(second.severity, .critical)
        XCTAssertEqual(second.package, "libx")
        XCTAssertNil(second.fixed)
    }

    func testSortingAndDedup() {
        let low = Vulnerability(cve: "B", package: "p", installed: "1", fixed: nil, severity: .low, title: "", url: nil)
        let high = Vulnerability(cve: "A", package: "p", installed: "1", fixed: nil, severity: .high, title: "", url: nil)
        XCTAssertEqual(VulnerabilityScanner.sorted([low, high, low]).map(\.cve), ["A", "B"])
    }

    func testDedupKeepsIDsUnique() {
        // Same id (CVE + package + version) but different title / fixed / severity: Trivy reports it under several targets.
        let a = Vulnerability(cve: "C", package: "p", installed: "1", fixed: nil, severity: .medium, title: "x", url: nil)
        let b = Vulnerability(cve: "C", package: "p", installed: "1", fixed: "2", severity: .high, title: "y", url: nil)
        let c = Vulnerability(cve: "C", package: "p", installed: "1", fixed: "2", severity: .high, title: "z", url: "u")
        let result = VulnerabilityScanner.sorted([a, b, c])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.severity, .high)
        XCTAssertEqual(result.first?.fixed, "2")
        let many = (0..<5_000).map { Vulnerability(cve: "CVE-\($0 % 500)", package: "p\($0 % 7)", installed: "1", fixed: nil, severity: .low, title: "\($0)", url: nil) }
        let unique = VulnerabilityScanner.sorted(many)
        XCTAssertEqual(Set(unique.map(\.id)).count, unique.count)
    }

    func testReferenceValidationAndArguments() {
        XCTAssertTrue(VulnerabilityScanner.isValidReference("ghcr.io/org/app:1.2@sha256:abc"))
        XCTAssertFalse(VulnerabilityScanner.isValidReference("--config=/etc/x"))
        XCTAssertFalse(VulnerabilityScanner.isValidReference("a b"))
        let (command, args) = VulnerabilityScanner.arguments(.trivy, image: "nginx:1", socketPath: "/s.sock")
        XCTAssertEqual(command, "trivy")
        XCTAssertEqual(args.last, "nginx:1")
        XCTAssertTrue(args.contains("unix:///s.sock"))
        XCTAssertEqual(VulnerabilityScanner.arguments(.scout, image: "nginx:1", socketPath: "/s").1.last, "local://nginx:1")
    }

    func testSeverityFromScore() {
        XCTAssertEqual(Vulnerability.Severity(score: 9.1), .critical)
        XCTAssertEqual(Vulnerability.Severity(score: 7.0), .high)
        XCTAssertEqual(Vulnerability.Severity(score: 5), .medium)
        XCTAssertEqual(Vulnerability.Severity(score: 1), .low)
        XCTAssertEqual(Vulnerability.Severity(score: 0), .unknown)
    }
}
