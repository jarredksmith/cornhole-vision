import Foundation

/// Wire format shared with the Cloudflare Worker and the web follow page.
/// Keep in sync with worker/src/index.js and web/index.html.

struct TeamInfo: Codable, Equatable {
    var name: String
    var color: String   // hex "#RRGGBB"
}

struct RoundCounts: Codable, Equatable {
    var on: Int = 0
    var inHole: Int = 0
    var points: Int { on + 3 * inHole }

    enum CodingKeys: String, CodingKey { case on, inHole = "in" }
}

struct RoundResult: Codable, Equatable, Identifiable {
    var id: Int { number }
    let number: Int
    let board: Int
    let a: RoundCounts
    let b: RoundCounts
    let pointsA: Int
    let pointsB: Int
}

struct LiveBag: Codable, Equatable {
    let id: Int
    let team: Int
    let x: Double
    let y: Double
    let state: String   // BagState raw value
}

struct LiveState: Codable, Equatable {
    var board: Int
    var bags: [LiveBag]
    var a: RoundCounts
    var b: RoundCounts
}

/// Full game state as the server broadcasts it.
struct GameState: Codable, Equatable {
    var code: String
    var status: String          // lobby | playing | finished
    var teams: [TeamInfo]
    var scores: [Int]
    var rounds: [RoundResult]
    var roundNumber: Int
    var activeBoard: Int
    var live: LiveState?
    var winner: Int?
    var target: Int
    var updatedAt: Double
}

// MARK: - Messages

struct OutboundMessage: Encodable {
    let type: String
    var role: String? = nil
    var board: Int? = nil
    var name: String? = nil
    var teams: [TeamInfo]? = nil
    var target: Int? = nil
    var live: LiveState? = nil
    var result: RoundResult? = nil
    var scores: [Int]? = nil
}

struct InboundMessage: Decodable {
    let type: String
    let state: GameState?
    let error: String?
}

enum GameCode {
    static func random() -> String {
        let letters = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String((0..<4).map { _ in letters.randomElement()! })
    }
}
