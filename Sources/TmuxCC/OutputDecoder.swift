import Foundation

/// Decode the escape format used in `%output` messages and in
/// command response lines (`capture-pane -e`, etc.).
///
/// tmux escapes control bytes (< 0x20) and the backslash byte as `\NNN`
/// (three octal digits). Everything else — including high bytes (0x80+)
/// that form UTF-8 multibyte sequences — passes through verbatim.
///
/// A lone `\` that isn't followed by three octal digits is passed through
/// as-is. Real tmux streams never produce that, but being permissive on
/// input costs nothing and makes the decoder safe to feed arbitrary data.
public enum OutputDecoder {

    public static func decode(_ input: String) -> Data {
        let bytes = Array(input.utf8)
        var result = Data()
        result.reserveCapacity(bytes.count)

        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5C /* '\' */,
               i + 3 < bytes.count,
               let value = parseOctalTriplet(bytes[i + 1], bytes[i + 2], bytes[i + 3])
            {
                result.append(UInt8(value))
                i += 4
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        return result
    }

    private static func parseOctalTriplet(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Int? {
        guard let d1 = octalValue(a),
              let d2 = octalValue(b),
              let d3 = octalValue(c) else {
            return nil
        }
        let v = (d1 << 6) | (d2 << 3) | d3
        return v <= 255 ? v : nil
    }

    private static func octalValue(_ b: UInt8) -> Int? {
        guard b >= 0x30 && b <= 0x37 else { return nil }
        return Int(b - 0x30)
    }
}
