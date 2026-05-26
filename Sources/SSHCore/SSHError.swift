import Foundation

public enum SSHError: Error, CustomStringConvertible, Sendable {
    case connectionFailed(underlying: String)
    case authenticationFailed(underlying: String?)
    case hostKeyRejected(host: String)
    case unsupportedKeyFormat(reason: String)
    case channelFailed(underlying: String)
    case execFailed(underlying: String)
    case alreadyDisconnected

    public var description: String {
        switch self {
        case .connectionFailed(let u):       return "Connection failed: \(u)"
        case .authenticationFailed(let u?):  return "Authentication failed: \(u)"
        case .authenticationFailed(nil):     return "Authentication failed"
        case .hostKeyRejected(let host):     return "Host key for \(host) was rejected"
        case .unsupportedKeyFormat(let r):   return "Unsupported key format: \(r)"
        case .channelFailed(let u):          return "Channel failure: \(u)"
        case .execFailed(let u):             return "Command execution failed: \(u)"
        case .alreadyDisconnected:           return "Connection already closed"
        }
    }
}
