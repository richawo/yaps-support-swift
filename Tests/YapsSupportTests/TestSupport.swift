import Foundation
import XCTest
@testable import YapsSupport

enum Fixtures {
    static var directory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try WireJSON.decoder().decode(T.self, from: data(name))
    }

    static func json(_ name: String) throws -> [AnyHashable: Any] {
        try JSONSerialization.jsonObject(with: data(name)) as! [AnyHashable: Any]
    }

    static var names: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()) ?? []
    }
}

/// Records requests and replays scripted responses per "METHOD /path".
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]
    }

    struct Recorded {
        var request: URLRequest
        var body: Data?

        var method: String { request.httpMethod ?? "GET" }
        var path: String { request.url?.path ?? "" }
        var json: [String: Any]? { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
        func query(_ name: String) -> String? {
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }
    }

    private let lock = NSLock()
    private var routes: [String: [Response]] = [:]
    private var recorded: [Recorded] = []

    func on(_ method: String, _ path: String, status: Int = 200, json: Any? = nil, data: Data? = nil, headers: [String: String] = [:]) {
        let body = data ?? json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)", default: []].append(Response(status: status, body: body, headers: headers))
    }

    func reset(_ method: String, _ path: String) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = nil
    }

    var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func requests(_ method: String, _ path: String) -> [Recorded] {
        requests.filter { $0.method == method && $0.path == path }
    }

    private func respond(_ request: URLRequest, body: Data?) -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(Recorded(request: request, body: body ?? request.httpBody))
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        var response = Response(status: 404, body: Data(#"{"error":{"code":"not_found","message":"no mock"}}"#.utf8), headers: [:])
        if var queue = routes[key], !queue.isEmpty {
            response = queue.count > 1 ? queue.removeFirst() : queue[0]
            routes[key] = queue
        }
        lock.unlock()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: response.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
        return (response.body, http)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        respond(request, body: nil)
    }

    func upload(_ request: URLRequest, body: Data, progress: @escaping @Sendable (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        progress(0.5)
        progress(1)
        return respond(request, body: body)
    }
}

/// A clock that advances only when the SDK "sleeps", so backoff runs instantly and deterministically.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_318_400)
    private(set) var sleeps: [TimeInterval] = []

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        sleeps.append(seconds)
        current = current.addingTimeInterval(seconds)
    }
}

@MainActor
final class EngineHarness {
    let transport = MockTransport()
    let clock = TestClock()
    let secureStore = MemorySecureStore()
    let settings = HostSettings()
    let directory: URL
    let defaults: UserDefaults
    private(set) var events: [SupportEvent] = []
    private(set) var engine: SupportEngine!

    init(appID: String = "app_123") {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("yaps-tests-\(UUID().uuidString)")
        let suite = "yaps-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        settings.onEvent = { [weak self] event in self?.events.append(event) }
        engine = makeEngine(appID: appID)
    }

    func makeEngine(appID: String = "app_123") -> SupportEngine {
        let clock = self.clock
        let deps = EngineDependencies(transport: transport, secureStore: secureStore, fileStore: FileStore(directory: directory),
                                      defaults: defaults, sleeper: { seconds in clock.advance(seconds) },
                                      now: { clock.now }, realtimeEnabled: false, systemIntegration: false)
        return SupportEngine(appID: appID, baseURL: URL(string: "https://support.test")!, settings: settings, deps: deps)
    }

    func stubRegister(token: String = "dt_reg_1_secret", verified: Bool = false, config: [String: Any] = [:]) {
        var cfg: [String: Any] = ["appId": "app_123", "appName": "Clucky", "verifiedOnly": false, "blocked": false,
                                  "trackedEvents": ["paywall_declined"], "translation": ["enabled": true, "customerLanguage": "es"],
                                  "teamDisplay": ["showNames": true, "showPhotos": true], "uploads": ["images": true, "files": true],
                                  "pollIntervalSeconds": 60]
        cfg.merge(config) { $1 }
        transport.on("POST", "/v1/sdk/register", status: 201, json: [
            "deviceToken": token, "registrationId": "reg_1",
            "customer": ["id": "cus_1", "verified": verified], "config": cfg,
        ])
    }

    func stubDeviceUpdate() {
        transport.on("PATCH", "/v1/sdk/device", json: ["customer": ["id": "cus_1", "verified": false]])
    }

    func cleanUp() {
        engine.teardown()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Polls `condition` on the main actor until it holds or the timeout passes.
@MainActor
func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

func message(id: String, seq: Int, author: AuthorType = .agent, text: String = "Hi", clientId: String? = nil,
             date: Date = Date(timeIntervalSince1970: 1_793_318_400)) -> Message {
    Message(id: id, conversationId: "cnv_1", seq: seq, clientId: clientId, author: Author(type: author, name: author == .agent ? "Frederick" : nil),
            text: text, createdAt: date.addingTimeInterval(TimeInterval(seq)))
}

func messageJSON(id: String, seq: Int, clientId: String? = nil, author: String = "customer", text: String = "Hello") -> [String: Any] {
    var json: [String: Any] = ["id": id, "conversationId": "cnv_1", "seq": seq, "author": ["type": author], "kind": "text",
                               "text": text, "attachments": [], "createdAt": "2026-10-30T09:41:00.000Z"]
    if let clientId { json["clientId"] = clientId }
    return json
}
