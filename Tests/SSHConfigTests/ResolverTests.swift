import XCTest
@testable import SSHConfig

final class ResolverTests: XCTestCase {
    private func resolve(
        _ text: String,
        host: String,
        user: String? = nil
    ) throws -> ResolvedConfig {
        // These tests don't use Include, so the loader is never invoked.
        let config = try SSHConfig(text: text, loader: DiskFileLoader())
        return config.resolve(host: host, user: user)
    }

    func test_hostBlockOverridesWildcard() throws {
        let r = try resolve("""
        Host special
            HostName 10.0.0.1
            Port 2222
        Host *
            Port 22
        """, host: "special")
        XCTAssertEqual(r.hostName, "10.0.0.1")
        XCTAssertEqual(r.port, 2222)
    }

    func test_firstMatchWins() throws {
        let r = try resolve("""
        Host foo
            Port 1111
        Host *
            Port 9999
        """, host: "foo")
        XCTAssertEqual(r.port, 1111)
    }

    func test_nonMatchingHostFallsBackToWildcard() throws {
        let r = try resolve("""
        Host foo
            Port 1111
        Host *
            Port 9999
        """, host: "bar")
        XCTAssertEqual(r.port, 9999)
    }

    func test_globalAppliesToAll() throws {
        let r = try resolve("""
        User alice
        Host specific
            User bob
        """, host: "other")
        XCTAssertEqual(r.user, "alice")
    }

    func test_wildcardSubdomain() throws {
        let r = try resolve("""
        Host *.example.com
            User wildcard
        """, host: "db.example.com")
        XCTAssertEqual(r.user, "wildcard")
    }

    func test_identityFilesAccumulate() throws {
        let r = try resolve("""
        Host *
            IdentityFile ~/.ssh/key1
            IdentityFile ~/.ssh/key2
        """, host: "anything")
        XCTAssertEqual(r.identityFiles, ["~/.ssh/key1", "~/.ssh/key2"])
    }

    func test_proxyJump() throws {
        let r = try resolve("""
        Host internal
            ProxyJump bastion
        """, host: "internal")
        XCTAssertEqual(r.proxyJump, "bastion")
    }

    func test_matchHost() throws {
        let r = try resolve("""
        Match host prod-*
            User ops
        """, host: "prod-db")
        XCTAssertEqual(r.user, "ops")
    }

    func test_matchUser() throws {
        let r = try resolve("""
        Match user deploy
            IdentityFile ~/.ssh/deploy_key
        """, host: "anything", user: "deploy")
        XCTAssertEqual(r.identityFiles, ["~/.ssh/deploy_key"])
    }

    func test_matchAll() throws {
        let r = try resolve("""
        Match all
            User everyone
        """, host: "anything")
        XCTAssertEqual(r.user, "everyone")
    }

    func test_negatedHostPatternBlocksMatch() throws {
        let r = try resolve("""
        Host * !bad.example.com
            User good
        """, host: "bad.example.com")
        XCTAssertNil(r.user)
    }

    func test_negatedHostPatternAllowsOthers() throws {
        let r = try resolve("""
        Host * !bad.example.com
            User good
        """, host: "ok.example.com")
        XCTAssertEqual(r.user, "good")
    }

    func test_preferredAuthenticationsSplit() throws {
        let r = try resolve("""
        Host *
            PreferredAuthentications publickey,password
        """, host: "anything")
        XCTAssertEqual(r.preferredAuthentications, ["publickey", "password"])
    }

    func test_proxyCommandPreservesSpaces() throws {
        let r = try resolve("""
        Host internal
            ProxyCommand ssh bastion nc %h %p
        """, host: "internal")
        XCTAssertEqual(r.proxyCommand, "ssh bastion nc %h %p")
    }
}
