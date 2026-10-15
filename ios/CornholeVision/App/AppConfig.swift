import Foundation

/// Edit these after you deploy the worker (see ../../worker/README.md).
enum AppConfig {
    /// Cloudflare Worker base URL, no trailing slash. Leave empty to run fully offline.
    /// Example: "https://cornhole-live.jarred.workers.dev"
    static let syncBaseURL = "https://cornhole-live.jarredksmith.workers.dev"

    /// Where the follow page lives (the web/ folder deployed to Pages / GitHub Pages).
    /// The share sheet sends  <followBaseURL>/?game=CODE
    /// Example: "https://cornhole.jarredsmith.com"
    static let followBaseURL = "https://cornhole-live.jarredksmith.workers.dev"

    /// Game to N points (ACL: 21, no bust).
    static let targetScore = 21

    /// Seconds of no motion on the board before a round auto-ends
    /// (used when fewer than 8 bags were seen, i.e. some missed the board).
    static let autoEndQuietSeconds = 12.0

    /// Seconds of no motion after the 8th bag lands before the round auto-ends.
    static let fullRoundQuietSeconds = 1.5
}
