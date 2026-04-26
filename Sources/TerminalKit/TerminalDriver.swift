#if canImport(UIKit)
import Foundation
import UIKit
import SwiftTerm

/// Hands bytes from the caller (e.g. an SSH output stream pump) into
/// the underlying `SwiftTerm.TerminalView`. Created by the caller and
/// passed into a `SwiftTermView`; the representable binds the live
/// view into the driver when it materializes.
@MainActor
public final class TerminalDriver {
    private weak var terminal: SwiftTerm.TerminalView?

    public init() {}

    /// Push bytes from the remote (or any source) into the terminal.
    /// Must be called on the main actor.
    public func feed(_ data: Data) {
        guard let terminal else { return }
        terminal.feed(byteArray: ArraySlice(data))
    }

    func bind(_ view: SwiftTerm.TerminalView) {
        terminal = view
    }
}
#endif
