import XCTest
@testable import SSHConfig

final class IncludeTests: XCTestCase {
    func test_simpleInclude() throws {
        let home = TempHome()
        let configURL = try home.write("""
        Include hosts.d/prod
        User fallback
        """, to: ".ssh/config")
        try home.write("""
        Host prod-db
            HostName 10.0.0.5
        """, to: ".ssh/hosts.d/prod")

        let config = try SSHConfig.load(url: configURL, loader: home.loader)
        let resolved = config.resolve(host: "prod-db")
        XCTAssertEqual(resolved.hostName, "10.0.0.5")
        XCTAssertEqual(resolved.user, "fallback")
    }

    func test_includeWithGlob() throws {
        let home = TempHome()
        let configURL = try home.write("Include conf.d/*", to: ".ssh/config")
        try home.write("Host a\n  User aaa", to: ".ssh/conf.d/a.conf")
        try home.write("Host b\n  User bbb", to: ".ssh/conf.d/b.conf")

        let config = try SSHConfig.load(url: configURL, loader: home.loader)
        XCTAssertEqual(config.resolve(host: "a").user, "aaa")
        XCTAssertEqual(config.resolve(host: "b").user, "bbb")
    }

    func test_includeWithinHostBlock() throws {
        let home = TempHome()
        let configURL = try home.write("""
        Host prod-db
            Include prod-common
        """, to: ".ssh/config")
        try home.write("""
        User ops
        Port 2222
        """, to: ".ssh/prod-common")

        let config = try SSHConfig.load(url: configURL, loader: home.loader)
        let r = config.resolve(host: "prod-db")
        XCTAssertEqual(r.user, "ops")
        XCTAssertEqual(r.port, 2222)
    }

    func test_includeCycleDetected() throws {
        let home = TempHome()
        let configURL = try home.write("Include a", to: ".ssh/config")
        try home.write("Include config", to: ".ssh/a")

        XCTAssertThrowsError(try SSHConfig.load(url: configURL, loader: home.loader)) { error in
            guard case .includeCycle = (error as? SSHConfigError)?.kind else {
                return XCTFail("expected includeCycle, got \(error)")
            }
        }
    }

    func test_missingIncludeDoesNotError() throws {
        let home = TempHome()
        let configURL = try home.write("""
        Include does-not-exist
        User alice
        """, to: ".ssh/config")

        let config = try SSHConfig.load(url: configURL, loader: home.loader)
        XCTAssertEqual(config.resolve(host: "anything").user, "alice")
    }

    func test_absoluteIncludePath() throws {
        let home = TempHome()
        let sharedURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("sshconfig-shared-\(UUID().uuidString)")
        try "Host shared\n  User s".write(to: sharedURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sharedURL) }

        let configURL = try home.write("Include \(sharedURL.path)", to: ".ssh/config")
        let config = try SSHConfig.load(url: configURL, loader: home.loader)
        XCTAssertEqual(config.resolve(host: "shared").user, "s")
    }

    func test_tildeIncludePath() throws {
        let home = TempHome()
        let configURL = try home.write("Include ~/.ssh/extra", to: ".ssh/config")
        try home.write("Host extra\n  User x", to: ".ssh/extra")

        let config = try SSHConfig.load(url: configURL, loader: home.loader)
        XCTAssertEqual(config.resolve(host: "extra").user, "x")
    }

    func test_includeAfterGlobalMergesCorrectly() throws {
        // Per OpenSSH first-match-wins: the global `User` is set before the
        // Host block from the include is considered, so `User` is "globaluser"
        // for every host. Non-conflicting keywords from the included Host
        // block (HostName, Port) still apply to matching hosts.
        let home = TempHome()
        let configURL = try home.write("""
        User globaluser
        Include more
        """, to: ".ssh/config")
        try home.write("""
        Host special
            HostName 10.0.0.9
            Port 2222
        """, to: ".ssh/more")

        let config = try SSHConfig.load(url: configURL, loader: home.loader)
        let special = config.resolve(host: "special")
        XCTAssertEqual(special.user, "globaluser")
        XCTAssertEqual(special.hostName, "10.0.0.9")
        XCTAssertEqual(special.port, 2222)

        let other = config.resolve(host: "other")
        XCTAssertEqual(other.user, "globaluser")
        XCTAssertNil(other.hostName)
    }
}
