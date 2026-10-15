import Foundation

/// Learns the two team colours from the first bags it sees — no setup step.
/// Team 0 is whichever colour lands first; team 1 is the first clearly different colour.
final class TeamColorModel {
    struct TeamColor {
        var r: Double, g: Double, b: Double
        var samples: Int

        /// Chromaticity (r/s, g/s) + normalised value — robust to shadows.
        var feature: (Double, Double, Double) {
            let s = r + g + b + 1
            return (r / s, g / s, s / 3 / 255)
        }

        var hex: String {
            String(format: "#%02X%02X%02X", Int(r.rounded()), Int(g.rounded()), Int(b.rounded()))
        }

        var name: String {
            TeamColorModel.nearestName(r: r, g: g, b: b)
        }
    }

    private(set) var teams: [TeamColor] = []
    /// Distance above which a colour is treated as the *other* team.
    var newTeamThreshold = 0.20

    func reset() { teams.removeAll() }

    /// Pre-populate the teams (from the host phone) with a low sample count so they still adapt.
    func seed(_ rgb: [(Double, Double, Double)]) {
        teams = rgb.prefix(2).map { TeamColor(r: $0.0, g: $0.1, b: $0.2, samples: 4) }
    }

    static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        2.2 * (abs(a.0 - b.0) + abs(a.1 - b.1)) + 0.55 * abs(a.2 - b.2)
    }

    /// Assign a colour to a team index (0 or 1), creating teams as they are discovered.
    func assign(r: Double, g: Double, b: Double, learn: Bool = true) -> Int {
        let f = TeamColor(r: r, g: g, b: b, samples: 1).feature
        if teams.isEmpty {
            teams.append(TeamColor(r: r, g: g, b: b, samples: 1))
            return 0
        }
        var best = 0
        var bestD = Double.infinity
        for (i, t) in teams.enumerated() {
            let d = TeamColorModel.distance(f, t.feature)
            if d < bestD { bestD = d; best = i }
        }
        if bestD > newTeamThreshold && teams.count < 2 {
            teams.append(TeamColor(r: r, g: g, b: b, samples: 1))
            return teams.count - 1
        }
        if learn {
            // Exponential moving average keeps up with changing light.
            var t = teams[best]
            let a = max(0.02, 1.0 / Double(min(t.samples + 1, 60)))
            t.r += (r - t.r) * a; t.g += (g - t.g) * a; t.b += (b - t.b) * a
            t.samples += 1
            teams[best] = t
        }
        return best
    }

    /// Named colours so the scoreboard can say "Red 7 – Blue 4".
    private static let named: [(String, Double, Double, Double)] = [
        ("Red", 200, 35, 40), ("Blue", 35, 75, 200), ("Black", 25, 25, 28), ("White", 235, 235, 230),
        ("Green", 35, 140, 60), ("Yellow", 240, 210, 40), ("Orange", 240, 125, 30), ("Purple", 110, 45, 165),
        ("Gray", 130, 130, 135), ("Teal", 25, 150, 150), ("Pink", 235, 90, 160), ("Navy", 20, 35, 90),
        ("Maroon", 120, 25, 40), ("Lime", 150, 220, 50), ("Tan", 200, 170, 120), ("Brown", 110, 70, 40),
    ]

    static func nearestName(r: Double, g: Double, b: Double) -> String {
        let f = TeamColor(r: r, g: g, b: b, samples: 1).feature
        var best = "Team"
        var bd = Double.infinity
        for (name, nr, ng, nb) in named {
            let d = distance(f, TeamColor(r: nr, g: ng, b: nb, samples: 1).feature)
            if d < bd { bd = d; best = name }
        }
        return best
    }
}
