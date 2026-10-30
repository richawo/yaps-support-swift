import Foundation

/// The HTTP layer, abstracted so tests can substitute a recorder.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupportError(code: SupportError.invalidResponse) }
        return (data, http)
    }

    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        let delegate = UploadProgressDelegate(progress: progress)
        let (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw SupportError(code: SupportError.invalidResponse) }
        progress(1)
        return (data, http)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// Retry delays from the protocol.
enum Backoff {
    /// REST and outbox: 1 s, 2 s, 4 s … capped at 60 s (PROTOCOL §1), with ±20 % jitter.
    static func rest(attempt: Int, jitter: Double = Double.random(in: -0.2...0.2)) -> TimeInterval {
        let base = min(60, pow(2, Double(max(0, attempt))))
        return base * (1 + jitter)
    }

    /// Socket reconnects: 1, 2, 4, 8, 16, 30 s with ±20 % jitter (PROTOCOL §4).
    static let socketSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    static func socket(attempt: Int, jitter: Double = Double.random(in: -0.2...0.2)) -> TimeInterval {
        let base = socketSchedule[min(max(0, attempt), socketSchedule.count - 1)]
        return base * (1 + jitter)
    }
}

enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", patch = "PATCH", put = "PUT", delete = "DELETE"
}

struct RetryPolicy: Sendable {
    var maxAttempts: Int

    static let none = RetryPolicy(maxAttempts: 1)
    static let standard = RetryPolicy(maxAttempts: 4)
}

/// Talks to the SDK endpoints of PROTOCOL §3.
struct APIClient: Sendable {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    let baseURL: URL
    let appID: String
    let transport: HTTPTransport
    let sleeper: Sleeper

    static let defaultSleeper: Sleeper = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    init(baseURL: URL, appID: String, transport: HTTPTransport, sleeper: @escaping Sleeper = APIClient.defaultSleeper) {
        self.baseURL = baseURL
        self.appID = appID
        self.transport = transport
        self.sleeper = sleeper
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    func makeRequest(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                     token: String?, extraHeaders: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method.rawValue
        request.setValue(appID, forHTTPHeaderField: "X-Support-App")
        request.setValue("ios/\(SDKInfo.version)", forHTTPHeaderField: "X-Support-SDK")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    /// Sends a request and decodes the JSON body. Retries 429 (after `retryAfter`), 5xx and
    /// transport failures with exponential backoff, up to `retry.maxAttempts` attempts.
    func send<Response: Decodable>(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [],
                                   body: (any Encodable)? = nil, token: String?,
                                   retry: RetryPolicy = .standard, as type: Response.Type = Response.self) async throws -> Response {
        let (data, _) = try await raw(method, path, query: query, body: body, token: token, retry: retry)
        do {
            return try WireJSON.decoder().decode(Response.self, from: data)
        } catch {
            throw SupportError(code: SupportError.invalidResponse, status: 200, message: "\(error)")
        }
    }

    /// Like `send` but ignores the body (204 responses).
    func sendVoid(_ method: HTTPMethod, _ path: String, body: (any Encodable)? = nil,
                  token: String?, retry: RetryPolicy = .standard) async throws {
        _ = try await raw(method, path, body: body, token: token, retry: retry)
    }

    func raw(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)?,
             token: String?, retry: RetryPolicy, extraHeaders: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let bodyData: Data?
        if let body {
            bodyData = try WireJSON.encoder().encode(body)
        } else {
            bodyData = nil
        }
        let request = makeRequest(method, path, query: query, body: bodyData, token: token, extraHeaders: extraHeaders)
        return try await perform(request, retry: retry)
    }

    func perform(_ request: URLRequest, retry: RetryPolicy, accept: Set<Int> = []) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await transport.send(request)
                if (200..<300).contains(response.statusCode) || accept.contains(response.statusCode) {
                    return (data, response)
                }
                throw Self.error(from: data, response: response)
            } catch let error as SupportError {
                guard error.isRetryable, attempt < retry.maxAttempts, !Task.isCancelled else { throw error }
                let delay = error.status == 429 ? (error.retryAfter ?? Backoff.rest(attempt: attempt - 1)) : Backoff.rest(attempt: attempt - 1)
                Log.debug("Request \(request.httpMethod ?? "") \(request.url?.path ?? "") failed with \(error.code); retrying in \(String(format: "%.1f", delay))s")
                try await sleeper(delay)
            } catch {
                let mapped = Self.transportError(error)
                guard mapped.isRetryable, attempt < retry.maxAttempts, !Task.isCancelled else { throw mapped }
                try await sleeper(Backoff.rest(attempt: attempt - 1))
            }
        }
    }

    static func transportError(_ error: Error) -> SupportError {
        if let error = error as? SupportError { return error }
        if error is CancellationError { return SupportError(code: SupportError.cancelled) }
        if let urlError = error as? URLError, urlError.code == .cancelled { return SupportError(code: SupportError.cancelled) }
        return SupportError(code: SupportError.connectionFailed, message: (error as NSError).localizedDescription)
    }

    /// Maps a non-2xx response to a `SupportError` using the §1 envelope.
    static func error(from data: Data, response: HTTPURLResponse) -> SupportError {
        let status = response.statusCode
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            var retryAfter = envelope.error.retryAfter
            if retryAfter == nil, let header = response.value(forHTTPHeaderField: "Retry-After") { retryAfter = TimeInterval(header) }
            return SupportError(code: envelope.error.code, status: status, retryAfter: retryAfter, message: envelope.error.message)
        }
        let code: String
        switch status {
        case 401: code = SupportError.unauthorized
        case 404: code = SupportError.notFound
        case 413: code = SupportError.tooLarge
        case 429: code = SupportError.rateLimited
        case 500...: code = SupportError.serverError
        default: code = "http_error"
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        return SupportError(code: code, status: status, retryAfter: retryAfter)
    }
}

struct Empty: Codable, Sendable {}

enum SDKInfo {
    static let version = "1.0.0"
}
