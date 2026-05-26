import Foundation
@testable import SSHKnownHosts

/// Test-only convenience: deterministic dummy key bytes derived from
/// a label. Real keys are random; for tests we just need stable,
/// distinguishable byte sequences.
enum Fixtures {
    static func key(_ label: String, length: Int = 32) -> Data {
        var bytes = Array(label.utf8)
        while bytes.count < length { bytes.append(contentsOf: bytes) }
        return Data(bytes.prefix(length))
    }

    static let ed25519 = "ssh-ed25519"
    static let rsa = "ssh-rsa"
}
