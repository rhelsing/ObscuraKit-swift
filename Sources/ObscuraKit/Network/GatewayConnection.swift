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

    private var envelopeQueue: [(id: Data, senderID: Data, timestamp: UInt64, message: Data)] = []
    private var waiters: [(id: Int, continuation: CheckedContinuation<(id: Data, senderID: Data, timestamp: UInt64, message: Data), Error>)] = []
    private var nextWaiterId = 0

    private var onPreKeyStatus: (@Sendable (Int32, Int32) -> Void)?

    /// DEBUG (flap diagnosis): each connect() gets a generation number so logs
    /// can attribute receive errors / ping failures to the socket that produced
    /// them — a mismatch (gen != current) proves a stale loop from an old socket
    /// is mutating live connection state.
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
        // DEBUG (flap diagnosis): prevSocket/prevPing=ALIVE on a reconnect means the
        // old socket/ping loop was never torn down and is still running alongside.
        logger.log("[gw] connect gen=\(gen) prevSocket=\(wsTask != nil ? "ALIVE" : "nil") prevPing=\(pingTask != nil ? "ALIVE" : "nil") wasConnected=\(isConnected)")
        receiveTask?.cancel()
        receiveTask = nil
        flushWaiters()
        envelopeQueue.removeAll()

        let ticket = try await api.fetchGatewayTicket()
        await rateLimitDelay()

        let baseURL = await api.baseURL
        let wsBase = baseURL.replacingOccurrences(of: "https://", with: "wss://")
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

    public func waitForRawEnvelope(timeout: TimeInterval = 10) async throws -> (id: Data, senderID: Data, timestamp: UInt64, message: Data) {
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
                        Task { await self?.handlePingFailure() }
                    }
                }
            }
        }
    }

    /// Ping failed — connection is dead. Disconnect so the envelope loop detects it.
    private func handlePingFailure() {
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
        // DEBUG (flap diagnosis): gen != current means a receive loop from an OLD
        // socket is running this — it will still set isConnected=false below and
        // kill the live connection. closeCode/reason say why the socket dropped
        // (1000=normal, 1001=goingAway, 1006=abnormal, -1=still open per URLSession).
        let reason = ws.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        logger.log("[gw] receive error gen=\(gen) current=\(socketGeneration) cancelled=\(cancelled) closeCode=\(ws.closeCode.rawValue) reason=\(reason) err=\(error)")
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
                let raw = (id: envelope.id, senderID: envelope.senderID, timestamp: envelope.timestamp, message: envelope.message)

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
