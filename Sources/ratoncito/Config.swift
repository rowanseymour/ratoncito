import Foundation

/// A mouse button, stored with user-facing 1-based numbering (1 = left, 2 = right, 3 = middle, …).
struct Button: Codable, Hashable, Comparable, CustomStringConvertible {
    let number: Int

    static let names = ["left": 1, "right": 2, "middle": 3, "back": 4, "forward": 5]

    init(_ number: Int) { self.number = number }

    init(parsing s: String) throws {
        if let n = Button.names[s.lowercased()] ?? Int(s), (1...32).contains(n) {
            self.init(n)
        } else {
            throw CLIError("invalid button \"\(s)\": use 1-32 or \(Button.names.keys.sorted().joined(separator: ", "))")
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) {
            self.init(n)
        } else {
            try self.init(parsing: c.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(number)
    }

    /// CGEvent button number (0-based).
    var cgButton: Int64 { Int64(number - 1) }

    var description: String {
        let name = Button.names.first { $0.value == number }?.key
        return name.map { "\(number) (\($0))" } ?? "\(number)"
    }

    static func < (a: Button, b: Button) -> Bool { a.number < b.number }
}

struct Mapping: Codable, Equatable {
    var from: Button
    var to: Button
}

struct Config: Codable, Equatable {
    var mappings: [Mapping] = []
    /// Physical buttons whose events are swallowed, e.g. a failing switch that double-fires.
    var blocked: [Button] = []

    static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("ratoncito/config.json")
    }

    /// Loads the config, or an empty one if the file doesn't exist.
    static func load(from url: URL) throws -> Config {
        guard let data = FileManager.default.contents(atPath: url.path) else { return Config() }
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw CLIError("can't parse \(url.path): \(error)")
        }
        try config.validate()
        return config
    }

    func save(to url: URL) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    func validate() throws {
        var seen = Set<Button>()
        for m in mappings {
            guard (1...32).contains(m.from.number), (1...32).contains(m.to.number) else {
                throw CLIError("buttons must be 1-32")
            }
            guard m.from != m.to else { throw CLIError("button \(m.from) is mapped to itself") }
            guard seen.insert(m.from).inserted else { throw CLIError("button \(m.from) is mapped more than once") }
            guard !blocked.contains(m.from) else { throw CLIError("button \(m.from) is both mapped and blocked") }
        }
    }

    var isEmpty: Bool { mappings.isEmpty && blocked.isEmpty }

    var summary: String {
        guard !isEmpty else { return "no mappings" }
        var lines = mappings.sorted { $0.from < $1.from }.map { "\($0.from) → \($0.to)" }
        lines += blocked.sorted().map { "\($0) blocked" }
        return lines.joined(separator: "\n")
    }
}
