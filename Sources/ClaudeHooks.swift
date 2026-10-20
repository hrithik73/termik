import AppKit

/// Connects Claude Code to Termik: tab status (OSC 7501), session resume and the usage footer.
/// Merges entries into ~/.claude/settings.json that run the scripts bundled in Termik.app/Contents/Resources/hooks.
enum ClaudeHooks {
    /// Resolved so a settings.json symlinked from a dotfiles repo is written through, not replaced.
    static var settingsFile: URL { URL(filePath: NSHomeDirectory()).appending(path: ".claude/settings.json").resolvingSymlinksInPath() }
    static var dir: String { Bundle.main.resourceURL!.appending(path: "hooks").path(percentEncoded: false) }

    /// Scripts that mark a hook as ours (ghostline-session is the pre-rename name), so reconnecting replaces them.
    private static let scripts = ["osc7501", "termik-session", "ghostline-session"]

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// `settings` with Termik's hooks and statusLine wrapper in place of any earlier ones; everything else is kept.
    static func merge(_ settings: [String: Any], dir: String) -> [String: Any] {
        func run(_ script: String, _ args: String) -> [String: Any] { ["type": "command", "command": "\(quote("\(dir)/\(script)")) \(args)"] }
        let ours: [String: [String: Any]] = [
            "SessionStart": ["hooks": [run("osc7501", "idle"), run("termik-session", "start")]],
            "UserPromptSubmit": ["hooks": [run("osc7501", "working Thinking")]],
            "PreToolUse": ["matcher": "*", "hooks": [run("osc7501", "working @tool")]],
            "Notification": ["hooks": [run("osc7501", "blocked 'Needs your input' permission")]],
            "Stop": ["hooks": [run("osc7501", "done Finished")]],
            "SessionEnd": ["hooks": [run("osc7501", "clear"), run("termik-session", "end")]],
        ]
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, group) in ours {
            let kept = (hooks[event] as? [[String: Any]] ?? []).compactMap { g -> [String: Any]? in
                let rest = (g["hooks"] as? [[String: Any]] ?? []).filter { h in
                    let command = h["command"] as? String ?? ""
                    return !scripts.contains { command.contains("/\($0)") }
                }
                var g = g
                g["hooks"] = rest
                return rest.isEmpty ? nil : g
            }
            hooks[event] = kept + [group]
        }
        settings["hooks"] = hooks

        // Only the statusLine receives Claude's rate limits, so wrap the user's own command rather than replace it.
        var line = settings["statusLine"] as? [String: Any] ?? ["type": "command"]
        let current = line["command"] as? String ?? ""
        let inner = current.range(of: "/termik-statusline'").map { String(current[$0.upperBound...]) }  // already wrapped
            ?? (current.isEmpty ? "" : " " + quote(current))
        line["command"] = quote("\(dir)/termik-statusline") + inner
        settings["statusLine"] = line
        return settings
    }

    static var isConnected: Bool { (try? String(contentsOf: settingsFile, encoding: .utf8))?.contains(dir) == true }

    /// Offers to connect once, on the first launch where Claude Code is set up but not connected.
    static func offer() {
        let claude = URL(filePath: NSHomeDirectory()).appending(path: ".claude")
        guard !UserDefaults.standard.bool(forKey: "claudeHooksOffered"),
              FileManager.default.fileExists(atPath: claude.path(percentEncoded: false)), !isConnected else { return }
        connect()
    }

    static func connect() {
        // A quarantined app runs from a random read-only copy; hooks pointing there break on the next launch.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            return alert("Remove Termik from quarantine first",
                         "Run this in a terminal, then reopen Termik:\n\nxattr -dr com.apple.quarantine /Applications/Termik.app")
        }
        UserDefaults.standard.set(true, forKey: "claudeHooksOffered")
        let ask = NSAlert()
        ask.messageText = "Connect Claude Code?"
        ask.informativeText = "Adds hooks and a statusLine wrapper to ~/.claude/settings.json so tabs show Claude's status, "
            + "sessions resume after a relaunch, and the footer shows your usage limits. "
            + "The current file is backed up to settings.json.bak."
        ask.addButton(withTitle: "Connect")
        ask.addButton(withTitle: "Not Now")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        let fm = FileManager.default
        let file = settingsFile
        do {
            var settings: [String: Any] = [:]
            if let data = try? Data(contentsOf: file) {
                // Never overwrite a file we can't parse.
                guard let s = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                settings = s
                let backup = file.appendingPathExtension("bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: file, to: backup)
            }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: merge(settings, dir: dir),
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: file, options: .atomic)
            alert("Claude Code connected", "Restart running Claude sessions to pick up the hooks.")
        } catch {
            alert("Couldn't update ~/.claude/settings.json", error.localizedDescription)
        }
    }

    private static func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }
}
