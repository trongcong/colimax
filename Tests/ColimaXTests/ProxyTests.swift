import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

final class ProxyTests: XCTestCase {
    func testRouteValidation() {
        XCTAssertTrue(ProxyRoute.isValidSubdomain("api"))
        XCTAssertTrue(ProxyRoute.isValidSubdomain("api.shop-1"))
        for bad in ["", "API", "-a", "a-", "a..b", "a b", "a;b", "a}b", "a/b", "{x}"] {
            XCTAssertFalse(ProxyRoute.isValidSubdomain(bad), bad)
        }
        XCTAssertFalse(ProxyRoute(subdomain: "a", container: "web", port: 0).isValid)
        XCTAssertFalse(ProxyRoute(subdomain: "a", container: "-web", port: 80).isValid)
        XCTAssertTrue(ProxyRoute(subdomain: "a", container: "web_1", port: 80).isValid)
    }

    func testSettingsURLs() {
        let route = ProxyRoute(subdomain: "app", container: "web", port: 80)
        XCTAssertEqual(ProxySettings().url(for: route), "https://app.localhost")
        XCTAssertEqual(ProxySettings(httpPort: 8080, httpsPort: 8443, https: true).url(for: route), "https://app.localhost:8443")
        XCTAssertEqual(ProxySettings(httpPort: 8080, httpsPort: 8443, https: false).url(for: route), "http://app.localhost:8080")
        XCTAssertFalse(ProxySettings(httpPort: 80, httpsPort: 80, https: true).isValid)
    }

    func testCaddyfile() {
        let a = LocalProxy.Upstream(route: ProxyRoute(subdomain: "b", container: "web", port: 80), address: "172.18.0.2:80")
        let b = LocalProxy.Upstream(route: ProxyRoute(subdomain: "a", container: "api", port: 3000), address: "172.17.0.3:3000")
        let https = LocalProxy.caddyfile([a, b], settings: ProxySettings())
        XCTAssertTrue(https.contains("default_bind 127.0.0.1"))
        XCTAssertTrue(https.contains("admin unix//tmp/caddy-admin.sock"))
        XCTAssertTrue(https.contains("local_certs"))
        XCTAssertTrue(https.contains("a.localhost {\n\treverse_proxy 172.17.0.3:3000\n}"))
        XCTAssertLessThan(https.range(of: "a.localhost")!.lowerBound, https.range(of: "b.localhost")!.lowerBound)
        let http = LocalProxy.caddyfile([a], settings: ProxySettings(httpPort: 8080, httpsPort: 8443, https: false))
        XCTAssertTrue(http.contains("auto_https off"))
        XCTAssertTrue(http.contains("http_port 8080"))
        XCTAssertTrue(http.contains("http://b.localhost {"))
        XCTAssertTrue(LocalProxy.caddyfile([], settings: ProxySettings()).contains("no routes"))
    }

    func testUpstreamPrefersUserNetworkIP() throws {
        let json = """
        {"Id":"x","Name":"/web","NetworkSettings":{"Networks":{
          "bridge":{"IPAddress":"172.17.0.5"},"app_default":{"IPAddress":"172.20.0.3"}}}}
        """
        let details = try JSONDecoder().decode(ContainerDetails.self, from: Data(json.utf8))
        let route = ProxyRoute(subdomain: "web", container: "web", port: 8080)
        XCTAssertEqual(try LocalProxy.upstream(for: route, target: details).address, "172.20.0.3:8080")
        let none = try JSONDecoder().decode(ContainerDetails.self, from: Data(#"{"Id":"x","Name":"/web","NetworkSettings":{"Networks":{"none":{"IPAddress":""}}}}"#.utf8))
        XCTAssertThrowsError(try LocalProxy.upstream(for: route, target: none))
    }

    func testAdminNotReadyDetection() {
        XCTAssertTrue(LocalProxy.isAdminNotReady(#"Post "http://localhost:2019/load": dial tcp 127.0.0.1:2019: connect: connection refused"#))
        XCTAssertTrue(LocalProxy.isAdminNotReady("dial unix /tmp/caddy-admin.sock: connect: no such file or directory (admin)"))
        XCTAssertFalse(LocalProxy.isAdminNotReady("Error: adapting config using caddyfile: unrecognized directive: foo"))
    }

    func testTarReaderRoundTrip() throws {
        let content = Data("-----BEGIN CERTIFICATE-----\nabc\n".utf8)
        var tar = try TarWriter.header(name: "root.crt", size: Int64(content.count))
        tar.append(content)
        tar.append(Data(count: Int(TarWriter.paddedSize(Int64(content.count))) - content.count + 1024))
        let entry = try XCTUnwrap(TarReader.firstFile(tar))
        XCTAssertEqual(entry.name, "root.crt")
        XCTAssertEqual(entry.data, content)
        XCTAssertNil(TarReader.firstFile(Data(count: 1024)))
        XCTAssertNil(TarReader.firstFile(Data("short".utf8)))
    }
}
