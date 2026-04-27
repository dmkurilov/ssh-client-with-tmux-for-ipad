import XCTest
@testable import SSHKnownHosts

final class MatchTests: XCTestCase {

    private let alpha = Fixtures.key("alpha")
    private let beta = Fixtures.key("beta")

    func test_unknownHost_returnsUnknown() {
        let kh = KnownHosts()
        XCTAssertEqual(
            kh.match(host: "novel.example.com", keyType: Fixtures.ed25519, keyData: alpha),
            .unknown
        )
    }

    func test_exactMatch() {
        let kh = KnownHosts().adding(
            host: "example.com",
            keyType: Fixtures.ed25519,
            keyData: alpha
        )
        XCTAssertEqual(
            kh.match(host: "example.com", keyType: Fixtures.ed25519, keyData: alpha),
            .match
        )
    }

    func test_mismatch_sameHostSameTypeDifferentKey() {
        let kh = KnownHosts().adding(
            host: "example.com",
            keyType: Fixtures.ed25519,
            keyData: alpha
        )
        let result = kh.match(host: "example.com", keyType: Fixtures.ed25519, keyData: beta)
        guard case .mismatch(let existing) = result else {
            return XCTFail("expected mismatch, got \(result)")
        }
        XCTAssertEqual(existing.keyData, alpha)
    }

    func test_differentKeyType_isUnknown() {
        // We have an Ed25519 entry but the server presents an RSA
        // key. That's not a mismatch (no compromise signal) — it's
        // just an unknown trust state for that key type.
        let kh = KnownHosts().adding(
            host: "example.com",
            keyType: Fixtures.ed25519,
            keyData: alpha
        )
        XCTAssertEqual(
            kh.match(host: "example.com", keyType: Fixtures.rsa, keyData: alpha),
            .unknown
        )
    }

    func test_revoked_winsOverMatchingKey() {
        let kh = KnownHosts().adding(
            host: "compromised.example.com",
            keyType: Fixtures.ed25519,
            keyData: alpha,
            marker: .revoked
        )
        let result = kh.match(
            host: "compromised.example.com",
            keyType: Fixtures.ed25519,
            keyData: alpha
        )
        guard case .revoked(let entry) = result else {
            return XCTFail("expected revoked, got \(result)")
        }
        XCTAssertEqual(entry.marker, .revoked)
    }

    func test_match_throughHashedPattern() {
        // Build a known_hosts containing a hashed entry for vpn.x and
        // verify the live host name resolves correctly.
        let pattern = HostPattern.hashed(host: "vpn.example.com")
        let entry = Entry(
            hostPatterns: [pattern],
            keyType: Fixtures.ed25519,
            keyData: alpha
        )
        let kh = KnownHosts(entries: [entry])
        XCTAssertEqual(
            kh.match(host: "vpn.example.com", keyType: Fixtures.ed25519, keyData: alpha),
            .match
        )
        XCTAssertEqual(
            kh.match(host: "other.example.com", keyType: Fixtures.ed25519, keyData: alpha),
            .unknown
        )
    }

    func test_portMatching_bracketedEntry() {
        let kh = KnownHosts().adding(
            host: "bastion.example.com",
            port: 2222,
            keyType: Fixtures.ed25519,
            keyData: alpha
        )
        // Same host, port match → match.
        XCTAssertEqual(
            kh.match(host: "bastion.example.com", port: 2222, keyType: Fixtures.ed25519, keyData: alpha),
            .match
        )
        // Same host, default port → unknown (entry is port-scoped).
        XCTAssertEqual(
            kh.match(host: "bastion.example.com", port: 22, keyType: Fixtures.ed25519, keyData: alpha),
            .unknown
        )
    }
}
