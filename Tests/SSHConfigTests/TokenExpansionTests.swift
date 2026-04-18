import XCTest
@testable import SSHConfig

final class TokenExpansionTests: XCTestCase {
    private func ctx(
        remoteHost: String? = "10.0.0.1",
        originalHost: String? = "prod-db",
        remoteUser: String? = "ops",
        remotePort: Int? = 22
    ) -> TokenContext {
        TokenContext(
            localUser: "alice",
            localHost: "macbook.local",
            localHostFQDN: "macbook.lan.example.com",
            remoteUser: remoteUser,
            remoteHost: remoteHost,
            originalHost: originalHost,
            remotePort: remotePort,
            homeDirectory: "/Users/alice"
        )
    }

    func test_literalPercent() {
        XCTAssertEqual(TokenExpander.expand("100%%", with: ctx()), "100%")
    }

    func test_remoteHostAndPort() {
        XCTAssertEqual(
            TokenExpander.expand("ssh %h:%p", with: ctx()),
            "ssh 10.0.0.1:22"
        )
    }

    func test_originalHost() {
        XCTAssertEqual(
            TokenExpander.expand("name=%n", with: ctx()),
            "name=prod-db"
        )
    }

    func test_remoteAndLocalUser() {
        XCTAssertEqual(
            TokenExpander.expand("%r@%u", with: ctx()),
            "ops@alice"
        )
    }

    func test_localHostShort() {
        XCTAssertEqual(
            TokenExpander.expand("%L", with: ctx()),
            "macbook"
        )
    }

    func test_localHostFQDN() {
        XCTAssertEqual(
            TokenExpander.expand("%l", with: ctx()),
            "macbook.lan.example.com"
        )
    }

    func test_homeDirectory() {
        XCTAssertEqual(
            TokenExpander.expand("%d/.ssh/known_hosts", with: ctx()),
            "/Users/alice/.ssh/known_hosts"
        )
    }

    func test_unknownTokenLeftIntact() {
        XCTAssertEqual(
            TokenExpander.expand("%Z", with: ctx()),
            "%Z"
        )
    }

    func test_missingRemoteHostLeavesTokenIntact() {
        XCTAssertEqual(
            TokenExpander.expand("%h", with: ctx(remoteHost: nil)),
            "%h"
        )
    }

    func test_trailingLonePercent() {
        XCTAssertEqual(
            TokenExpander.expand("value=50%", with: ctx()),
            "value=50%"
        )
    }
}
