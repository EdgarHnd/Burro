// A minimal client for a Convex deployment's public HTTP API (`/api/query`, `/api/mutation`).
// Burro talks to Maurice's `edgar-app` backend for shared to-dos. No SDK, no websocket, no
// background polling of its own: callers decide when to sync. The owner token is passed as a
// function argument (Maurice's functions check it) and is never logged.
import Foundation

public struct ConvexConfig: Sendable, Equatable {
    public var url: URL
    public var token: String
    public init(url: URL, token: String) { self.url = url; self.token = token }

    /// Accepts only HTTPS Convex cloud hosts, so a mistyped URL can't receive the token.
    public static func validURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$()", with: "")
        guard let url = URL(string: trimmed), url.scheme == "https", let host = url.host,
              host.hasSuffix(".convex.cloud"), url.user == nil, url.password == nil else { return nil }
        return URL(string: "https://" + host)
    }

    /// Reads `CONVEX_URL` and `EDGAR_API_TOKEN` from Maurice's `Config/Secrets.xcconfig`
    /// (which escapes `//` as `/$()/`).
    public static func parseXcconfig(_ text: String) -> ConvexConfig? {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            guard !raw.hasPrefix("//"), let equals = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<equals].trimmingCharacters(in: .whitespaces)
            values[key] = raw[raw.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        guard let url = values["CONVEX_URL"].flatMap(validURL), let token = values["EDGAR_API_TOKEN"],
              token.count >= 16, !token.contains(where: \.isWhitespace) else { return nil }
        return ConvexConfig(url: url, token: token)
    }
}

public enum ConvexClientError: Error, Equatable, LocalizedError {
    /// The server refused on purpose (a `ConvexError` with a message meant for people).
    case refused(String)
    case unauthorized
    case server(String)
    case transport(String)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .refused(let message): message
        case .unauthorized: "Convex rejected the token. Import it again in Settings."
        case .server: "Convex couldn't run that request."
        case .transport(let message): message
        case .decoding: "Convex sent a response Burro doesn't understand."
        }
    }
    /// Worth retrying later (offline, timeouts); refusals and auth problems are not.
    public var isRetryable: Bool { if case .transport = self { true } else { false } }
}

public struct ConvexClient: Sendable {
    public let config: ConvexConfig
    private let session: URLSession
    public init(config: ConvexConfig, session: URLSession = ConvexClient.defaultSession) {
        self.config = config; self.session = session
    }
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public func query<Result: Decodable>(_ path: String, _ args: some Encodable & Sendable, as: Result.Type = Result.self) async throws -> Result {
        try await call("query", path, args)
    }
    public func mutation<Result: Decodable>(_ path: String, _ args: some Encodable & Sendable, as: Result.Type = Result.self) async throws -> Result {
        try await call("mutation", path, args)
    }

    private struct Body<Args: Encodable>: Encodable {
        let path: String
        let args: Args
        let format = "json"
    }
    /// Convex wraps every result; errors carry a message and, for `ConvexError`, user-facing data.
    struct Envelope<Value: Decodable>: Decodable {
        let status: String
        let value: Value?
        let errorMessage: String?
        let errorData: ErrorData?
        enum CodingKeys: String, CodingKey { case status, value, errorMessage, errorData }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decode(String.self, forKey: .status)
            errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
            errorData = try? c.decodeIfPresent(ErrorData.self, forKey: .errorData)
            guard status == "success" else { value = nil; return }
            // `null` results (mutations that return nothing) decode from an empty object instead.
            value = try c.decodeIfPresent(Value.self, forKey: .value)
                ?? (try? JSONDecoder().decode(Value.self, from: Data("{}".utf8)))
        }
    }
    struct ErrorData: Decodable {
        let message: String?
        init(from decoder: Decoder) throws { message = try? decoder.singleValueContainer().decode(String.self) }
    }

    private func call<Args: Encodable & Sendable, Result: Decodable>(_ kind: String, _ path: String, _ args: Args) async throws -> Result {
        var request = URLRequest(url: config.url.appendingPathComponent("api").appendingPathComponent(kind))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(path: path, args: TokenArgs(token: config.token, rest: args)))
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ConvexClientError.transport((error as? URLError)?.code == .notConnectedToInternet ? "You're offline." : "Couldn't reach Convex.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard data.count <= 4 * 1024 * 1024 else { throw ConvexClientError.decoding }
        guard let envelope = try? JSONDecoder().decode(Envelope<Result>.self, from: data) else {
            if status >= 500 || status == 0 { throw ConvexClientError.transport("Convex is unavailable right now.") }
            throw ConvexClientError.decoding
        }
        if envelope.status == "success", let value = envelope.value { return value }
        let message = envelope.errorData?.message ?? ""
        if message == "unauthorized" || (envelope.errorMessage ?? "").contains("unauthorized") { throw ConvexClientError.unauthorized }
        if !message.isEmpty { throw ConvexClientError.refused(message) }
        throw ConvexClientError.server(envelope.errorMessage ?? "HTTP \(status)")
    }
}

/// Adds `token` alongside the call's own arguments in one flat JSON object.
private struct TokenArgs<Rest: Encodable>: Encodable {
    let token: String
    let rest: Rest
    func encode(to encoder: Encoder) throws {
        try rest.encode(to: encoder)
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(token, forKey: Key(stringValue: "token")!)
    }
    struct Key: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

/// For mutations that return nothing (`null`).
public struct ConvexVoid: Decodable, Sendable {
    public init(from decoder: Decoder) throws {}
}
