import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SwiftProtobuf

/// WebSocket gateway connection for real-time message delivery.
/// Mirrors src/v2/api/gateway.js
public class GatewayConnection {
    private let api: APIClient
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveHandler: ((Obscura_V1_Envelope) -> Void)?
    private var preKeyStatusHandler: ((Obscura_V1_PreKeyStatus) -> Void)?
    private var isConnected = false

    // Message queue for waitForMessage pattern
    private var messageQueue: [Obscura_V1_Envelope] = []
    private var messageResolvers: [CheckedContinuation<Obscura_V1_Envelope, Error>] = []

    public init(api: APIClient) {
        self.api = api
    }

    /// Connect to WebSocket gateway
    public func connect() async throws {
        let ticket = try await api.fetchGatewayTicket()
        await rateLimitDelay()

        guard let url = await api.getGatewayURL(ticket: ticket) else {
            throw GatewayError.invalidURL
        }

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        isConnected = true

        // Start receive loop
        Task { await receiveLoop() }
    }

    /// Disconnect
    public func disconnect() {
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// Wait for next envelope with timeout
    /// Wait for next envelope with timeout. Returns raw envelope data.
    public func waitForRawEnvelope(timeout: TimeInterval = 10) async throws -> (id: Data, senderID: Data, timestamp: UInt64, message: Data) {
        let envelope = try await waitForEnvelopeInternal(timeout: timeout)
        return (id: envelope.id, senderID: envelope.senderID, timestamp: envelope.timestamp, message: envelope.message)
    }

    func waitForEnvelopeInternal(timeout: TimeInterval = 10) async throws -> Obscura_V1_Envelope {
        // Check queue first
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }

        // Wait for next message
        return try await withCheckedThrowingContinuation { continuation in
            messageResolvers.append(continuation)

            // Timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // If still waiting, fail
                if let index = messageResolvers.firstIndex(where: { $0 as AnyObject === continuation as AnyObject }) {
                    messageResolvers.remove(at: index)
                    continuation.resume(throwing: GatewayError.timeout)
                }
            }
        }
    }

    /// Send acknowledgment for processed messages
    public func acknowledge(_ envelopeIds: [Data]) async throws {
        var ack = Obscura_V1_AckMessage()
        ack.messageIds = envelopeIds

        var frame = Obscura_V1_WebSocketFrame()
        frame.ack = ack

        let data = try frame.serializedData()
        try await task?.send(.data(data))
    }

    // MARK: - Private

    private func receiveLoop() async {
        guard let task = task else { return }

        while isConnected {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let data):
                    try handleFrame(data)
                case .string(let string):
                    if let data = string.data(using: .utf8) {
                        try handleFrame(data)
                    }
                @unknown default:
                    break
                }
            } catch {
                if isConnected {
                    // Connection dropped
                    isConnected = false
                }
                break
            }
        }
    }

    private func handleFrame(_ data: Data) throws {
        let frame = try Obscura_V1_WebSocketFrame(serializedData: data)

        if case .envelopeBatch(let batch) = frame.payload {
            for envelope in batch.envelopes {
                // Deliver to waiting resolver or queue
                if !messageResolvers.isEmpty {
                    let resolver = messageResolvers.removeFirst()
                    resolver.resume(returning: envelope)
                } else {
                    messageQueue.append(envelope)
                }
            }
        } else if case .preKeyStatus(let status) = frame.payload {
            preKeyStatusHandler?(status)
        }
    }

    public enum GatewayError: Error {
        case invalidURL
        case notConnected
        case timeout
    }
}
