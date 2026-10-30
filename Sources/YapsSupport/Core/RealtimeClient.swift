import Foundation

/// The chat socket (PROTOCOL §4). Opened only while the chat is visible and the app is active.
/// Sends `hello` with the last seq on every (re)connect, pings every 25 s, and reconnects with
/// jittered backoff (1, 2, 4, 8, 16, 30 s). Unknown frames are ignored.
@MainActor
final class RealtimeClient {
    enum State: Equatable {
        case idle
        case connecting(attempt: Int)
        case connected
        /// The socket closed; a reconnect is scheduled. `failures` counts consecutive failures.
        case waiting(failures: Int, retryAt: Date)
    }

    enum Failure: Equatable {
        case unauthorized
        case other(status: Int?)
    }

    var onFrame: ((ServerFrame) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onFailure: ((Failure) -> Void)?

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let session: URLSession
    private let makeURL: () -> URL?
    private let lastSeq: () -> Int
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var pingLoop: Task<Void, Never>?
    private var reconnectTimer: Task<Void, Never>?
    private var failures = 0
    private var lastInbound = Date()
    private var generation = 0

    static let pingInterval: TimeInterval = 25

    init(session: URLSession = URLSession(configuration: .default), makeURL: @escaping () -> URL?, lastSeq: @escaping () -> Int) {
        self.session = session
        self.makeURL = makeURL
        self.lastSeq = lastSeq
    }

    var isConnected: Bool { state == .connected }

    func start() {
        guard task == nil, reconnectTimer == nil else { return }
        connect()
    }

    func stop() {
        generation += 1
        reconnectTimer?.cancel()
        reconnectTimer = nil
        teardown()
        failures = 0
        state = .idle
    }

    /// Reconnect immediately (on app resume or network change), resetting the backoff.
    func reconnectNow() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        failures = 0
        teardown()
        connect()
    }

    @discardableResult
    func send(_ frame: ClientFrame) -> Bool {
        guard let task, state == .connected || frameAllowedBeforeWelcome(frame) else { return false }
        let text = String(decoding: frame.encoded(), as: UTF8.self)
        task.send(.string(text)) { error in
            if let error { Log.debug("Socket send failed: \((error as NSError).code)") }
        }
        return true
    }

    private func frameAllowedBeforeWelcome(_ frame: ClientFrame) -> Bool {
        if case .hello = frame { return true }
        return false
    }

    private func connect() {
        guard let url = makeURL() else { return }
        generation += 1
        let current = generation
        state = .connecting(attempt: failures)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
        self.task = task
        task.resume()
        send(.hello(after: lastSeq()))
        lastInbound = Date()
        receiveLoop = Task { [weak self] in
            await self?.receive(task: task, generation: current)
        }
        pingLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == current else { return }
                if Date().timeIntervalSince(self.lastInbound) > Self.pingInterval * 2.5 {
                    Log.debug("Socket went quiet; reconnecting")
                    self.handleClose(generation: current, status: nil)
                    return
                }
                self.send(.ping)
            }
        }
    }

    private func receive(task: URLSessionWebSocketTask, generation current: Int) async {
        let decoder = WireJSON.decoder()
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard generation == current else { return }
                lastInbound = Date()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                do {
                    let frame = try ServerFrame.decode(data, decoder: decoder)
                    if case .welcome = frame {
                        failures = 0
                        state = .connected
                    }
                    if case .unknown(let type) = frame {
                        Log.debug("Ignoring unknown socket frame \(type)")
                        continue
                    }
                    onFrame?(frame)
                } catch {
                    Log.debug("Ignoring undecodable socket frame")
                }
            } catch {
                guard generation == current else { return }
                let status = (task.response as? HTTPURLResponse)?.statusCode
                handleClose(generation: current, status: status)
                return
            }
        }
    }

    private func handleClose(generation current: Int, status: Int?) {
        guard generation == current else { return }
        teardown()
        if status == 401 {
            onFailure?(.unauthorized)
        } else {
            onFailure?(.other(status: status))
        }
        failures += 1
        let delay = Backoff.socket(attempt: failures - 1)
        state = .waiting(failures: failures, retryAt: Date().addingTimeInterval(delay))
        reconnectTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTimer = nil
            self.connect()
        }
    }

    private func teardown() {
        receiveLoop?.cancel()
        receiveLoop = nil
        pingLoop?.cancel()
        pingLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
