import Foundation

/// Shared helpers so ALWM's own GitHub calls (updates, stars, credits) stay under quota.
enum GitHubAPIRateLimit {
    /// Unauthenticated public GitHub API is ~60 req/hour — keep app traffic sparse.
    static let publicMinInterval: TimeInterval = 6 * 60 * 60
    /// Star / meta refresh can be a bit fresher than update checks.
    static let starsMinInterval: TimeInterval = 60 * 60
    static let creditsMinInterval: TimeInterval = 12 * 60 * 60

    static func retryAfter(from http: HTTPURLResponse) -> Date {
        if let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init), retry > 0 {
            return Date().addingTimeInterval(retry)
        }
        if let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init) {
            let date = Date(timeIntervalSince1970: reset)
            if date > Date() { return date }
        }
        // Conservative backoff when headers are missing.
        return Date().addingTimeInterval(15 * 60)
    }

    static func isRateLimited(_ http: HTTPURLResponse) -> Bool {
        if http.statusCode == 403 || http.statusCode == 429 { return true }
        if let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           remaining == "0" {
            return true
        }
        return false
    }
}
