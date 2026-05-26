import XCTest
@testable import SSHKnownHosts

final class HostPatternTests: XCTestCase {

    func test_plainHost_matchesSameHostAnyPort() {
        let p = HostPattern.plain(host: "example.com", port: nil)
        XCTAssertTrue(p.matches(host: "example.com", port: 22))
        XCTAssertTrue(p.matches(host: "example.com", port: 2222))
        XCTAssertFalse(p.matches(host: "other.com", port: 22))
    }

    func test_bracketedHostWithPort_requiresPortMatch() {
        let p = HostPattern.plain(host: "bastion.example.com", port: 2222)
        XCTAssertTrue(p.matches(host: "bastion.example.com", port: 2222))
        XCTAssertFalse(p.matches(host: "bastion.example.com", port: 22))
        XCTAssertFalse(p.matches(host: "other.example.com", port: 2222))
    }

    func test_hashedPattern_matchesViaHMAC() {
        // Build a hashed pattern for a known host, then verify the
        // pattern matches that host but not others.
        let pattern = HostPattern.hashed(host: "vpn.example.com")
        XCTAssertTrue(pattern.matches(host: "vpn.example.com", port: 22))
        XCTAssertFalse(pattern.matches(host: "other.example.com", port: 22))
    }

    func test_hashedPattern_isPortAgnostic() {
        // Hashed entries don't encode a port — they always match
        // regardless of the candidate port.
        let pattern = HostPattern.hashed(host: "vpn.example.com")
        XCTAssertTrue(pattern.matches(host: "vpn.example.com", port: 22))
        XCTAssertTrue(pattern.matches(host: "vpn.example.com", port: 2222))
    }
}
