import Foundation

enum LaunchAgent {
    static let label = "local.ratoncito"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ratoncito.log")
    }

    private static var domain: String { "gui/\(getuid())" }

    static func install(binDir: URL, config: URL, verbose: Bool) throws {
        let fm = FileManager.default
        guard let src = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw CLIError("can't determine path of running executable")
        }
        let dest = binDir.appendingPathComponent("ratoncito")

        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        if src.path != dest.resolvingSymlinksInPath().path {
            // Remove rather than overwrite: replacing a signed binary's contents in place (same inode)
            // can get the running/next process killed by the kernel's code signing cache.
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        }

        // Always pass the config path: launchd doesn't see the shell's XDG_CONFIG_HOME.
        var args = [dest.path, "run", "--config", config.path]
        if verbose { args.append("--verbose") }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": args,
            "RunAtLoad": true,
            // Restart after crashes, but not after a clean exit or a missing-permission/empty-config
            // exit, which would otherwise re-trigger the Accessibility prompt in a loop.
            "KeepAlive": ["Crashed": true],
            "ProcessType": "Interactive",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)

        _ = launchctl(["bootout", "\(domain)/\(label)"])
        try bootstrap()

        print("Installed \(dest.path)")
        print("LaunchAgent \(plistURL.path) loaded: \(args.dropFirst().joined(separator: " "))")
        print("Logs: \(logURL.path)")
        if isAdHocSigned(dest) {
            print("""

            warning: binary is ad-hoc signed, so its Accessibility grant won't survive a rebuild.
                     See README (code signing) and reinstall with `make install`.
            """)
        }
        print("""

        If Accessibility isn't granted yet, macOS will prompt now and the agent will exit.
        Enable \(dest.path) in System Settings → Privacy & Security → Accessibility, then run:
            ratoncito restart
        """)
    }

    static func uninstall() throws {
        let fm = FileManager.default
        var binary: String?
        if let data = fm.contents(atPath: plistURL.path),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = plist["ProgramArguments"] as? [String] {
            binary = args.first
        }

        _ = launchctl(["bootout", "\(domain)/\(label)"])
        if fm.fileExists(atPath: plistURL.path) {
            try fm.removeItem(at: plistURL)
            print("Removed \(plistURL.path)")
        } else {
            print("No LaunchAgent at \(plistURL.path)")
        }
        if let binary, fm.fileExists(atPath: binary) {
            try fm.removeItem(atPath: binary)
            print("Removed \(binary)")
        }
        print("You can also remove ratoncito from System Settings → Privacy & Security → Accessibility.")
    }

    static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]).status == 0 }

    /// Restarts the agent so it picks up config changes. Returns false if it isn't installed.
    @discardableResult
    static func restart() throws -> Bool {
        guard isLoaded else { return false }
        let result = launchctl(["kickstart", "-k", "\(domain)/\(label)"])
        guard result.status == 0 else { throw CLIError("launchctl kickstart failed (\(result.status)): \(result.output)") }
        return true
    }

    private static func bootstrap() throws {
        // bootout completes asynchronously, so an immediate bootstrap can fail with EIO; retry briefly.
        var result = (status: Int32(0), output: "")
        for _ in 0..<10 {
            result = launchctl(["bootstrap", domain, plistURL.path])
            if result.status == 0 { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw CLIError("launchctl bootstrap failed (\(result.status)): \(result.output)")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        run("/bin/launchctl", args)
    }

    private static func isAdHocSigned(_ url: URL) -> Bool {
        run("/usr/bin/codesign", ["-dv", url.path]).output.contains("Signature=adhoc")
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
