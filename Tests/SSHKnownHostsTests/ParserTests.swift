import XCTest
@testable import SSHKnownHosts

final class ParserTests: XCTestCase {

    func test_emptyAndCommentLines_skipped() {
        let kh = KnownHosts(text: """

        # this is a comment
            # leading whitespace
        """)
        XCTAssertEqual(kh.entries.count, 0)
    }

    func test_plainHost_singlePattern() {
        let key = Fixtures.key("alpha")
        let line = "example.com \(Fixtures.ed25519) \(key.base64EncodedString())"
        let kh = KnownHosts(text: line)
        XCTAssertEqual(kh.entries.count, 1)
        let entry = kh.entries[0]
        XCTAssertEqual(entry.marker, .none)
        XCTAssertEqual(entry.keyType, Fixtures.ed25519)
        XCTAssertEqual(entry.keyData, key)
        XCTAssertEqual(entry.hostPatterns, [.plain(host: "example.com", port: nil)])
        XCTAssertNil(entry.comment)
    }

    func test_multipleCommaSeparatedPatterns() {
        let key = Fixtures.key("a")
        let line = "host1.example.com,host2,1.2.3.4 \(Fixtures.ed25519) \(key.base64EncodedString())"
        let kh = KnownHosts(text: line)
        XCTAssertEqual(kh.entries.first?.hostPatterns, [
            .plain(host: "host1.example.com", port: nil),
            .plain(host: "host2", port: nil),
            .plain(host: "1.2.3.4", port: nil),
        ])
    }

    func test_bracketedHostWithPort() {
        let key = Fixtures.key("b")
        let line = "[bastion.example.com]:2222 \(Fixtures.rsa) \(key.base64EncodedString())"
        let kh = KnownHosts(text: line)
        XCTAssertEqual(
            kh.entries.first?.hostPatterns,
            [.plain(host: "bastion.example.com", port: 2222)]
        )
    }

    func test_revokedMarker() {
        let key = Fixtures.key("c")
        let line = "@revoked compromised.example.com \(Fixtures.ed25519) \(key.base64EncodedString())"
        let kh = KnownHosts(text: line)
        XCTAssertEqual(kh.entries.first?.marker, .revoked)
    }

    func test_certAuthorityMarker() {
        let key = Fixtures.key("d")
        let line = "@cert-authority *.example.com \(Fixtures.ed25519) \(key.base64EncodedString())"
        let kh = KnownHosts(text: line)
        XCTAssertEqual(kh.entries.first?.marker, .certAuthority)
    }

    func test_trailingCommentPreserved() {
        let key = Fixtures.key("e")
        let line = "example.com \(Fixtures.ed25519) \(key.base64EncodedString()) rotated 2026-04-01"
        let kh = KnownHosts(text: line)
        XCTAssertEqual(kh.entries.first?.comment, "rotated 2026-04-01")
    }

    func test_hashedHostPattern_parsesSaltAndHash() {
        let salt = Data([0x01, 0x02, 0x03, 0x04])
        let hash = Data([0x10, 0x20, 0x30, 0x40])
        let pattern = "|1|\(salt.base64EncodedString())|\(hash.base64EncodedString())"
        let key = Fixtures.key("f")
        let line = "\(pattern) \(Fixtures.ed25519) \(key.base64EncodedString())"
        let kh = KnownHosts(text: line)
        XCTAssertEqual(
            kh.entries.first?.hostPatterns,
            [.hashed(salt: salt, hash: hash)]
        )
    }

    func test_malformedLine_skippedSilently() {
        // Truncated, missing keytype + key.
        let kh = KnownHosts(text: "example.com\nanotherhost.example.org \(Fixtures.ed25519) \(Fixtures.key("g").base64EncodedString())")
        XCTAssertEqual(kh.entries.count, 1)
        XCTAssertEqual(kh.entries.first?.hostPatterns.first, .plain(host: "anotherhost.example.org", port: nil))
    }

    func test_invalidBase64Key_skipped() {
        let kh = KnownHosts(text: "example.com \(Fixtures.ed25519) ###NOTBASE64###")
        XCTAssertEqual(kh.entries.count, 0)
    }

    func test_crlfLineEndings() {
        let key = Fixtures.key("h")
        let text = "host1 \(Fixtures.ed25519) \(key.base64EncodedString())\r\nhost2 \(Fixtures.rsa) \(key.base64EncodedString())\r\n"
        let kh = KnownHosts(text: text)
        XCTAssertEqual(kh.entries.count, 2)
        XCTAssertEqual(kh.entries[0].keyType, Fixtures.ed25519)
        XCTAssertEqual(kh.entries[1].keyType, Fixtures.rsa)
    }
}
