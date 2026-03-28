import Foundation
import NIOCore
import NIOPosix
import WebSocketKit
import SwiftProtobuf

/// WebSocket gateway connection for real-time message delivery.
/// Uses WebSocketKit (SwiftNIO) for Linux compatibility.
public class GatewayConnection {
    private let api: APIClient
    private var ws: WebSocket?
    private let eventLoopGroup: EventLoopGroup
    private var isConnected = false

    // Message queue for waitForMessage pattern
    private var envelopeQueue: [(id: Data, senderID: Data, timestamp: UInt64, message: Data)] = []
    private var waiters: [CheckedContinuation<(id: Data, senderID: Data, timestamp: UInt64, message: Data), Error>] = []

    public init(api: APIClient) {
        self.api = api
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }

    /// Connect to WebSocket gateway
    public func connect() async throws {
        let ticket = try await api.fetchGatewayTicket()
        await rateLimitDelay()

        let baseURL = await api.baseURL
        let wsBase = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let urlString = "\(wsBase)/v1/gateway?ticket=\(ticket)"

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            WebSocket.connect(to: urlString, on: eventLoopGroup) { ws in
                self.ws = ws
                self.isConnected = true

                ws.onBinary { ws, buffer in
                    let data = Data(buffer: buffer)
                    self.handleFrame(data)
                }

                ws.onClose.whenComplete { _ in
                    self.isConnected = false
                }

                continuation.resume()
            }.whenFailure { error in
                continuation.resume(throwing: error)
            }
        }
    }

    /// Disconnect
    public func disconnect() {
        isConnected = false
        _ = ws?.close()
        ws = nil
    }

    /// Wait for next envelope with timeout
    public func waitForRawEnvelope(timeout: TimeInterval = 10) async throws -> (id: Data, senderID: Data, timestamp: UInt64, message: Data) {
        // Check queue first
        if !envelopeQueue.isEmpty {
            return envelopeQueue.removeFirst()
        }

        // Wait for next message with timeout
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
        var ack = Obscura_V1_AckMessage()
        ack.messageIds = envelopeIds

        var frame = Obscura_V1_WebSocketFrame()
        frame.ack = ack

        let data = try frame.serializedData()
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        ws?.send(raw: buffer.readableBytesView, opcode: .binary)
    }

    // MARK: - Private

    private func handleFrame(_ data: Data) {
        guard let frame = try? Obscura_V1_WebSocketFrame(serializedData: data) else { return }

        if case .envelopeBatch(let batch) = frame.payload {
            for envelope in batch.envelopes {
                let raw = (id: envelope.id, senderID: envelope.senderID, timestamp: envelope.timestamp, message: envelope.message)

                if !waiters.isEmpty {
                    let waiter = waiters.removeFirst()
                    waiter.resume(returning: raw)
                } else {
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
