// ratoncito — remap mouse buttons on macOS.

import AppKit

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let usage = """
usage: ratoncito [run] [--verbose]
       ratoncito map <from> <to>
       ratoncito unmap <from>
       ratoncito block <button>
       ratoncito unblock <button>
       ratoncito list
       ratoncito install [--verbose] [--bin-dir <dir>]
       ratoncito uninstall
       ratoncito restart

Remaps mouse buttons, including drag and double-click, using mappings stored in a
config file. Commands that change the config restart the installed agent.

commands:
  run        remap buttons until interrupted (default)
  map        make button <from> act as button <to>
  unmap      remove the mapping for a button
  block      swallow a physical button's events
  unblock    stop blocking a button
  list       show the config
  install    copy the binary and load a LaunchAgent that runs it at login
  uninstall  unload and remove the LaunchAgent and installed binary
  restart    restart the installed agent, e.g. after editing the config by hand

buttons: 1-32, or left (1), right (2), middle (3), back (4), forward (5)

options:
  --config <path>   config file (default: $XDG_CONFIG_HOME/ratoncito/config.json,
                    falling back to ~/.config/ratoncito/config.json)
  --verbose         log remapped and blocked clicks
  --bin-dir <dir>   install: where to copy the binary (default: ~/.local/bin)
  -h, --help        show this help
"""

struct Invocation {
    var command = "run"
    var positionals: [String] = []
    var configPath: URL?
    var verbose = false
    var binDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")

    var configURL: URL { configPath ?? Config.defaultURL }
}

let commandArity = ["run": 0, "map": 2, "unmap": 1, "block": 1, "unblock": 1, "list": 0,
                    "install": 0, "uninstall": 0, "restart": 0]

func parseArgs(_ argv: [String]) throws -> Invocation {
    var inv = Invocation()
    var args = argv[...]
    var positionals: [String] = []

    func value(for flag: String) throws -> String {
        guard let v = args.popFirst() else { throw CLIError("\(flag) requires a value") }
        return v
    }
    func path(_ s: String) -> URL { URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }

    while let arg = args.popFirst() {
        switch arg {
        case "--config": inv.configPath = path(try value(for: arg))
        case "--verbose": inv.verbose = true
        case "--bin-dir": inv.binDir = path(try value(for: arg))
        case "-h", "--help":
            print(usage)
            exit(0)
        case _ where arg.hasPrefix("-"): throw CLIError("unknown option: \(arg)")
        default: positionals.append(arg)
        }
    }

    if let first = positionals.first {
        guard commandArity[first] != nil else { throw CLIError("unknown command: \(first)") }
        inv.command = first
        inv.positionals = Array(positionals.dropFirst())
    }
    let arity = commandArity[inv.command]!
    guard inv.positionals.count == arity else {
        throw CLIError("\(inv.command) takes \(arity) argument\(arity == 1 ? "" : "s")")
    }
    return inv
}

/// Applies an edit to the config file, then restarts the agent if it's installed.
func editConfig(_ inv: Invocation, _ edit: (inout Config) throws -> Void) throws {
    var config = try Config.load(from: inv.configURL)
    try edit(&config)
    try config.save(to: inv.configURL)
    print(config.summary)
    if try LaunchAgent.restart() { print("Restarted agent.") }
}

/// Checks Accessibility permission, showing the system prompt if missing. Exits if not granted.
func requireAccessibility() {
    // Value of kAXTrustedCheckOptionPrompt, which Swift 6 rejects as a mutable global.
    let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) { return }

    // TCC attributes the request to the "responsible" process: the terminal app when run from a
    // shell, the binary itself when run by launchd.
    let who: String
    if getppid() == 1 {
        who = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    } else {
        let term = ProcessInfo.processInfo.environment["TERM_PROGRAM"].map { " (\($0))" } ?? ""
        who = "your terminal app\(term)"
    }
    FileHandle.standardError.write(Data("""
    ratoncito needs Accessibility permission to intercept mouse events.

    Grant it in: System Settings → Privacy & Security → Accessibility
    Enable:      \(who)

    If it's already listed and enabled, the grant is stale (the binary was re-signed):
    remove it with "−", add it again, then re-run ratoncito.

    """.utf8))
    exit(1)
}

func run(_ inv: Invocation) throws {
    let config = try Config.load(from: inv.configURL)
    guard !config.isEmpty else {
        throw CLIError("no mappings in \(inv.configURL.path); add one with e.g. `ratoncito map back left`")
    }

    requireAccessibility()

    let remapper = Remapper(config: config, verbose: inv.verbose)
    guard remapper.start() else { throw CLIError("failed to create event tap — check Accessibility permission") }
    print(config.summary)
    print("Running. Ctrl-C to quit.")
    CFRunLoopRun()
}

setvbuf(stdout, nil, _IOLBF, 0)

let inv: Invocation
do {
    inv = try parseArgs(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("ratoncito: \(error)\n\n\(usage)\n".utf8))
    exit(2)
}

do {
    let p = inv.positionals
    switch inv.command {
    case "map":
        let from = try Button(parsing: p[0]), to = try Button(parsing: p[1])
        try editConfig(inv) { c in
            c.mappings.removeAll { $0.from == from }
            c.mappings.append(Mapping(from: from, to: to))
        }
    case "unmap":
        let b = try Button(parsing: p[0])
        try editConfig(inv) { c in
            guard c.mappings.contains(where: { $0.from == b }) else { throw CLIError("button \(b) isn't mapped") }
            c.mappings.removeAll { $0.from == b }
        }
    case "block":
        let b = try Button(parsing: p[0])
        try editConfig(inv) { c in if !c.blocked.contains(b) { c.blocked.append(b) } }
    case "unblock":
        let b = try Button(parsing: p[0])
        try editConfig(inv) { c in
            guard c.blocked.contains(b) else { throw CLIError("button \(b) isn't blocked") }
            c.blocked.removeAll { $0 == b }
        }
    case "list":
        print("# \(inv.configURL.path)")
        print(try Config.load(from: inv.configURL).summary)
    case "install":
        try LaunchAgent.install(binDir: inv.binDir, config: inv.configURL, verbose: inv.verbose)
    case "uninstall":
        try LaunchAgent.uninstall()
    case "restart":
        guard try LaunchAgent.restart() else { throw CLIError("agent isn't installed") }
        print("Restarted agent.")
    default:
        try run(inv)
    }
} catch {
    FileHandle.standardError.write(Data("ratoncito: \(error)\n".utf8))
    exit(1)
}
