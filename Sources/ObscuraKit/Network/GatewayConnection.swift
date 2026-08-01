import Foundation
import SwiftProtobuf

/// WebSocket gateway connection for real-time message delivery.
/// Actor isolation ensures envelopeQueue and waiters are never accessed concurrently.
public actor GatewayConnection {
    private let api: APIClient
    private let logger: ObscuraLogger
    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    /// Ping interval in seconds — keeps connection alive through proxies/NATs.
    private static let pingIntervalSeconds: UInt64 = 30

    private var envelopeQueue: [(id: Data, senderID: Data, senderDeviceID: Data, timestamp: UInt64, message: Data)] = []
    private var waiters: [(id: Int, continuation: CheckedContinuation<(id: Data, senderID: Data, senderDeviceID: Data, timestamp: UInt64, message: Data), Error>)] = []
    private var nextWaiterId = 0

    private var onPreKeyStatus: (@Sendable (Int32, Int32) -> Void)?

    /// Each `connect()` gets a generation number, and every loop it starts carries that number.
    ///
    /// This began as a debug aid for flap diagnosis and is now load-bearing: `handleReceiveError`
    /// and `handlePingFailure` both refuse to touch connection state unless their generation is
    /// still the current one. Without that guard a loop belonging to a socket that has already been
    /// replaced sets `isConnected = false` and flushes the NEW connection's waiters, tearing down a
    /// live connection and provoking a reconnect that opens yet another socket.
    private var socketGeneration = 0

    public func setOnPreKeyStatus(_ handler: (@Sendable (Int32, Int32) -> Void)?) {
        onPreKeyStatus = handler
    }

    public init(api: APIClient, logger: ObscuraLogger = PrintLogger()) {
        self.api = api
        self.logger = logger
    }

    public func connect() async throws {
        socketGeneration += 1
        let gen = socketGeneration
        logger.log("[gw] connect gen=\(gen) prevSocket=\(wsTask != nil ? "ALIVE" : "nil") prevPing=\(pingTask != nil ? "ALIVE" : "nil") wasConnected=\(isConnected)")

        // TEAR THE OLD SOCKET DOWN FIRST. This used to cancel only `receiveTask` and then overwrite
        // `wsTask`/`wsSession`, dropping the previous socket and URLSession on the floor —
        // `ObscuraClient.connect()` never calls `disconnect()` first and runs this on every
        // reconnect, on foreground, and from `processPendingMessages`. Cancelling the receive task
        // does not reach it either: it is parked in `await ws.receive()`, which is not a
        // cancellation point, so the loop only wakes when the socket eventually errors — by which
        // time it belongs to a generation that is no longer current, and it would tear down the LIVE
        // connection (the generation guards below are the second half of this fix).
        //
        // `cancel(with:)` closes the socket and `invalidateAndCancel()` releases the URLSession,
        // which otherwise retains its delegate and its connection for the life of the process.
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        flushWaiters()
        envelopeQueue.removeAll()

        let ticket = try await api.fetchGatewayTicket()
        await rateLimitDelay()

        let baseURL = await api.baseURL
        let wsBase = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let encodedTicket = ticket.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ticket
        let urlString = "\(wsBase)/v1/gateway?ticket=\(encodedTicket)"

        guard let url = URL(string: urlString) else {
            throw GatewayError.invalidURL
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.wsSession = session
        self.wsTask = task
        self.isConnected = true
        logger.log("[gw] socket open gen=\(gen)")
        startReceiveLoop(gen: gen)
        startPingLoop(gen: gen)
    }

    public func disconnect() {
        logger.log("[gw] disconnect (intentional) gen=\(socketGeneration)")
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        flushWaiters()
        envelopeQueue.removeAll()
    }

    /// Fire-and-forget disconnect for deinit / sync contexts.
    nonisolated public func disconnectSync() {
        Task { await disconnect() }
    }

    public func waitForRawEnvelope(timeout: TimeInterval = 10) async throws -> (id: Data, senderID: Data, senderDeviceID: Data, timestamp: UInt64, message: Data) {
        if !envelopeQueue.isEmpty {
            return envelopeQueue.removeFirst()
        }

        let waiterId = nextWaiterId
        nextWaiterId += 1

        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((id: waiterId, continuation: continuation))

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.timeoutWaiter(id: waiterId)
            }
        }
    }

    public func acknowledge(_ envelopeIds: [Data]) throws {
        guard let wsTask = wsTask else { throw GatewayError.notConnected }

        var ack = Obscura_V1_AckMessage()
        ack.messageIds = envelopeIds

        var frame = Obscura_V1_WebSocketFrame()
        frame.ack = ack

        let data = try frame.serializedData()
        wsTask.send(.data(data)) { error in
            if let error = error {
                NSLog("[ObscuraKit] ack send error: %@", "\(error)")
            }
        }
    }

    // MARK: - Private

    private func timeoutWaiter(id: Int) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: idx)
            waiter.continuation.resume(throwing: GatewayError.timeout)
        }
    }

    private func flushWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(throwing: GatewayError.notConnected)
        }
    }

    /// Send WebSocket ping every 30 seconds to keep the connection alive.
    /// If ping fails (no pong), mark as disconnected so the envelope loop triggers reconnect.
    private func startPingLoop(gen: Int) {
        pingTask?.cancel()
        guard let ws = wsTask else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled, let self = self else { break }
                ws.sendPing { [weak self] error in
                    if let error = error {
                        NSLog("[ObscuraKit] [gw] ping FAILED gen=%d: %@", gen, "\(error)")
                        Task { await self?.handlePingFailure(gen: gen) }
                    }
                }
            }
        }
    }

    /// Ping failed — connection is dead. Disconnect so the envelope loop detects it.
    private func handlePingFailure(gen: Int) {
        // A ping loop belonging to a replaced socket must not touch live state. This one was worse
        // than `handleReceiveError`: it also cancelled the CURRENT `receiveTask` and `wsTask`, so a
        // stale ping failure killed a healthy connection outright.
        guard gen == socketGeneration else {
            logger.log("[gw] ignoring ping failure from stale gen=\(gen) (current=\(socketGeneration))")
            return
        }
        guard isConnected else { return }
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        flushWaiters() // This wakes the envelope loop with .notConnected error
    }

    private func startReceiveLoop(gen: Int) {
        guard let ws = wsTask else { return }
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await ws.receive()
                    guard let self = self else { break }
                    switch message {
                    case .data(let data):
                        await self.handleFrame(data)
                    case .string(_):
                        break
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self = self else { break }
                    await self.handleReceiveError(error, gen: gen, cancelled: Task.isCancelled, ws: ws)
                    break
                }
            }
        }
    }

    private func handleReceiveError(_ error: Error, gen: Int, cancelled: Bool, ws: URLSessionWebSocketTask) {
        // closeCode/reason say why the socket dropped (1000=normal, 1001=goingAway, 1006=abnormal,
        // -1=still open per URLSession).
        let reason = ws.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        logger.log("[gw] receive error gen=\(gen) current=\(socketGeneration) cancelled=\(cancelled) closeCode=\(ws.closeCode.rawValue) reason=\(reason) err=\(error)")

        // `gen != socketGeneration` means this is the death rattle of a socket `connect()` already
        // replaced. The receive loop cannot be cancelled out of `await ws.receive()`, so it always
        // arrives here eventually — and without this guard it sets `isConnected = false` and
        // flushes the waiters of the LIVE connection, which the envelope loop reads as a drop. That
        // schedules a reconnect, which opens another socket, which orphans another loop.
        guard gen == socketGeneration else { return }
        isConnected = false
        flushWaiters()
    }

    private func handleFrame(_ data: Data) {
        let frame: Obscura_V1_WebSocketFrame
        do {
            frame = try Obscura_V1_WebSocketFrame(serializedData: data)
        } catch {
            logger.frameParseFailed(byteCount: data.count, error: "\(error)")
            return
        }

        if case .preKeyStatus(let status) = frame.payload {
            onPreKeyStatus?(status.oneTimePreKeyCount, status.minThreshold)
        } else if case .envelopeBatch(let batch) = frame.payload {
            for envelope in batch.envelopes {
                let raw = (id: envelope.id, senderID: envelope.senderID, senderDeviceID: envelope.senderDeviceID, timestamp: envelope.timestamp, message: envelope.message)

                if !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    waiter.continuation.resume(returning: raw)
                } else {
                    if envelopeQueue.count >= 1000 { envelopeQueue.removeFirst() }
                    envelopeQueue.append(raw)
                }
            }
        }
    }

    public enum GatewayError: Error {
        case invalidURL
        case notConnected
        case timeout
    }
}
