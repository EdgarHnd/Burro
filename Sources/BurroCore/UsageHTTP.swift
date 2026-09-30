// Credential-bearing usage requests are bounded, ephemeral, and never follow redirects.
import Foundation
import Darwin

enum UsageHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: UsageNoRedirect(), delegateQueue: nil)
    }
    static func get(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageIssue.unavailable }
        try ClaudeUsageReader.validate(status: response.statusCode)
        if let status = response.value(forHTTPHeaderField: "grpc-status"), status != "0" { throw UsageIssue.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < UsageDecoding.maxBytes else { throw UsageIssue.unsupported }
            data.append(byte)
        }
        return data
    }
}

enum UsageFile {
    static func read(_ url: URL, limit: Int = UsageDecoding.maxBytes) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw errno == ENOENT ? UsageIssue.signInRequired : .unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= limit else { throw UsageIssue.unavailable }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw UsageIssue.unsupported }
        return data
    }
}
