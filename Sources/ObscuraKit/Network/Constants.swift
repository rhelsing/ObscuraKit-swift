import Foundation

// MARK: - Server Rate Limits
//
// Per-instance limits (3 instances behind load balancer):
//   General endpoints: 10 req/s sustained, 20 req/s burst
//   Auth endpoints:     1 req/s sustained,  3 req/s burst
//
// Auth endpoints: POST /v1/users, POST /v1/sessions, POST /v1/sessions/refresh
// All other endpoints use the general limit.
//
// Since requests are load-balanced across 3 instances, effective limits
// are ~3x these values in practice, but don't rely on that.

/// Delay between general API requests (ms). 100ms = 10 req/s.
public var SERVER_REQUEST_DELAY_MS: UInt64 = 100

/// Delay between auth API requests (ms). 1000ms = 1 req/s.
public var AUTH_REQUEST_DELAY_MS: UInt64 = 1000

/// Sleep helper for rate limiting between general server calls.
public func rateLimitDelay() async {
    try? await Task.sleep(nanoseconds: SERVER_REQUEST_DELAY_MS * 1_000_000)
}

/// Sleep helper for rate limiting between auth calls (register, login, refresh).
public func authRateLimitDelay() async {
    try? await Task.sleep(nanoseconds: AUTH_REQUEST_DELAY_MS * 1_000_000)
}
