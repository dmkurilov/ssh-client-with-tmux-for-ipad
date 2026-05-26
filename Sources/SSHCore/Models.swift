import Foundation

/// Where to connect: host, TCP port, and remote username.
public struct SSHEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let user: String

    public init(host: String, port: Int = 22, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }
}

/// How to authenticate. v1 supports password, OpenSSH-PEM ed25519
/// private keys, and the raw 32-byte Curve25519 form (which is what
/// the in-app Keychain store hands us for generated keys, so we
/// don't have to round-trip through OpenSSH PEM encoding).
/// Passphrase-encrypted keys, RSA, ECDSA, and others are deferred.
public enum Credentials: Sendable {
    case password(String)
    case privateKey(Data)
    case ed25519Raw(Data)   // 32-byte raw Curve25519 seed
}

/// Output of a one-shot remote command.
public struct SSHExecResult: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int

    public init(stdout: Data, stderr: Data, exitCode: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}
