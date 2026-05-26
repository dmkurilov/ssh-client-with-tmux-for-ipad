import XCTest
@testable import SSHKnownHosts

final class RoundTripTests: XCTestCase {

    func test_serializeAndReparse_preservesEntries() {
        let original = KnownHosts(entries: [
            Entry(
                hostPatterns: [.plain(host: "example.com", port: nil)],
                keyType: Fixtures.ed25519,
                keyData: Fixtures.key("alpha")
            ),
            Entry(
                marker: .revoked,
                hostPatterns: [.plain(host: "compromised.example.com", port: nil)],
                keyType: Fixtures.ed25519,
                keyData: Fixtures.key("revoked")
            ),
            Entry(
                hostPatterns: [.plain(host: "bastion.example.com", port: 2222)],
                keyType: Fixtures.rsa,
                keyData: Fixtures.key("bastion"),
                comment: "added 2026-04-26"
            ),
            Entry(
                hostPatterns: [.hashed(salt: Data([0x01, 0x02, 0x03]), hash: Data([0x10, 0x20]))],
                keyType: Fixtures.ed25519,
                keyData: Fixtures.key("hashed-host")
            ),
        ])

        let text = original.serialized()
        let reparsed = KnownHosts(text: text)

        XCTAssertEqual(reparsed.entries, original.entries)
    }

    func test_writeToDisk_andReadBack() throws {
        let home = TempHome()
        let path = home.url.appendingPathComponent("known_hosts")

        let original = KnownHosts().adding(
            host: "example.com",
            keyType: Fixtures.ed25519,
            keyData: Fixtures.key("disk-test")
        )

        try original.write(to: path)
        let loaded = try KnownHosts.load(url: path)

        XCTAssertEqual(loaded.entries, original.entries)
    }

    func test_addingEntry_appendsAndPersists() throws {
        let home = TempHome()
        let path = home.url.appendingPathComponent("known_hosts")

        let initial = KnownHosts().adding(
            host: "alpha.example.com",
            keyType: Fixtures.ed25519,
            keyData: Fixtures.key("alpha")
        )
        try initial.write(to: path)

        // TOFU prompt accepted: append a new entry.
        let extended = try KnownHosts.load(url: path).adding(
            host: "beta.example.com",
            keyType: Fixtures.ed25519,
            keyData: Fixtures.key("beta")
        )
        try extended.write(to: path)

        let final = try KnownHosts.load(url: path)
        XCTAssertEqual(final.entries.count, 2)

        XCTAssertEqual(
            final.match(host: "alpha.example.com", keyType: Fixtures.ed25519, keyData: Fixtures.key("alpha")),
            .match
        )
        XCTAssertEqual(
            final.match(host: "beta.example.com", keyType: Fixtures.ed25519, keyData: Fixtures.key("beta")),
            .match
        )
    }
}
