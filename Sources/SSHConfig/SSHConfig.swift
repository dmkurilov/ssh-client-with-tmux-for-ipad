import Foundation

public struct SSHConfig: Sendable {
    public let blocks: [Block]
    public let source: URL?

    public init(
        text: String,
        source: URL? = nil,
        loader: FileLoader = DiskFileLoader(),
        maxIncludeDepth: Int = 16
    ) throws {
        let parser = Parser(loader: loader, maxIncludeDepth: maxIncludeDepth)
        self.blocks = try parser.parse(text: text, source: source)
        self.source = source
    }

    public static func load(
        url: URL,
        loader: FileLoader = DiskFileLoader(),
        maxIncludeDepth: Int = 16
    ) throws -> SSHConfig {
        let text = try loader.read(url)
        return try SSHConfig(
            text: text,
            source: url,
            loader: loader,
            maxIncludeDepth: maxIncludeDepth
        )
    }

    public func resolve(
        host: String,
        user: String? = nil,
        originalHost: String? = nil,
        port: Int? = nil
    ) -> ResolvedConfig {
        let context = ResolutionContext(
            host: host,
            originalHost: originalHost,
            user: user,
            port: port
        )
        return Resolver().resolve(blocks: blocks, context: context)
    }
}
