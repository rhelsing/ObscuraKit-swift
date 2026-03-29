import Foundation

/// Minimum delay between server API requests (ms) to avoid rate limiting
public let SERVER_REQUEST_DELAY_MS: UInt64 = 200

/// Sleep helper for rate limiting between server calls
public func rateLimitDelay() async {
    try? await Task.sleep(nanoseconds: SERVER_REQUEST_DELAY_MS * 1_000_000)
}
