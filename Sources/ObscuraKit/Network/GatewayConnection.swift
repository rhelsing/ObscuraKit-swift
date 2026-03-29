import Foundation
import SwiftProtobuf

/// WebSocket gateway connection for real-time message delivery.
/// Uses URLSessionWebSocketTask (native Foundation, macOS 13+ / iOS 16+).
public class GatewayConnection {
    private let api: APIClient
    private let logger: ObscuraLogger
    private var wsTask: URLSessionWebSocketTask?
    private var wsSession: URLSession?
    private var isConnected = false
    private var receiveTask: Task<Void, Never>?

    // Message queue for waitForMessage pattern
    private var envelopeQueue: [(id: Data, senderID: Data, timestamp: UInt64, message: Data)] = []
    private var waiters: [CheckedContinuation<(id: Data, senderID: Data, timestamp: UInt64, message: Data), Error>] = []

    /// Callback for PreKeyStatus frames from server
    public var onPreKeyStatus: ((Int32, Int32) -> Void)?  // (count, minThreshold)

    public init(api: APIClient, logger: ObscuraLogger = PrintLogger()) {
        self.api = api
        self.logger = logger
    }

    /// Connect to WebSocket gateway
    public func connect() async throws {
        // Clean up any previous connection
        receiveTask?.cancel()
        receiveTask = nil
        flushWaiters()
        envelopeQueue.removeAll()

        let ticket = try await api.fetchGatewayTicket()
        await rateLimitDelay()

        let baseURL = await api.baseURL
        let wsBase = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
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
        startReceiveLoop()
    }

    /// Disconnect
    public func disconnect() {
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        flushWaiters()
        envelopeQueue.removeAll()
    }

    /// Wait for next envelope with timeout
    public func waitForRawEnvelope(timeout: TimeInterval = 10) async throws -> (id: Data, senderID: Data, timestamp: UInt64, message: Data) {
        if !envelopeQueue.isEmpty {
            return envelopeQueue.removeFirst()
        }

        return try await withThrowingTaskGroup(of: (id: Data, senderID: Data, timestamp: UInt64, message: Data).self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.waiters.append(continuation)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw GatewayError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Send acknowledgment for processed messages
    public func acknowledge(_ envelopeIds: [Data]) throws {
        guard let wsTask = wsTask else { throw GatewayError.notConnected }

        var ack = Obscura_V1_AckMessage()
        ack.messageIds = envelopeIds

        var frame = Obscura_V1_WebSocketFrame()
        frame.ack = ack

        let data = try frame.serializedData()
        wsTask.send(.data(data)) { [weak self] error in
            if let error = error {
                self?.logger.ackFailed(envelopeId: "batch", error: "\(error)")
            }
        }
    }

    // MARK: - Private

    private func flushWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: GatewayError.notConnected)
        }
    }

    private func startReceiveLoop() {
        guard let ws = wsTask else { return }
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await ws.receive()
                    guard let self = self else { break }
                    switch message {
                    case .data(let data):
                        self.handleFrame(data)
                    case .string(_):
                        break
                    @unknown default:
                        break
                    }
                } catch {
                    guard let self = self else { break }
                    self.isConnected = false
                    self.flushWaiters()
                    if !Task.isCancelled {
                        self.logger.frameParseFailed(byteCount: 0, error: "receive loop: \(error)")
                    }
                    break
                }
            }
        }
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
                    waiter.resume(returning: raw)
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
