// Self-check for ClaudeHooks.merge. Run: scripts/test-hooks.sh
import Foundation

@main struct TestHooks {
    static func main() {
        let user: [String: Any] = [
            "model": "opus",
            "statusLine": ["type": "command", "command": "bash ~/.claude/status.sh", "padding": 0],
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "say done"],
                                    ["type": "command", "command": "/old/ghostline/hooks/osc7501 done Finished"]]]],
                "SessionStart": [["hooks": [["type": "command", "command": "/old/ghostline/hooks/ghostline-session start"]]]],
            ],
        ]
        // Connect, then reconnect after the app moved: only the latest entries remain.
        let once = ClaudeHooks.merge(user, dir: "/Applications/Termik.app/Contents/Resources/hooks")
        let twice = ClaudeHooks.merge(once, dir: "/Moved/Termik.app/Contents/Resources/hooks")
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: twice, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)

        precondition(!json.contains("/old/") && !json.contains("/Applications/"), "stale entries removed")
        precondition(json.contains("say done") && json.contains(#""model":"opus""#), "user settings kept")
        let hooks = twice["hooks"] as! [String: Any]
        precondition((hooks["Stop"] as! [[String: Any]]).count == 2, "user group kept beside ours")
        precondition((hooks["SessionStart"] as! [[String: Any]]).count == 1, "emptied group dropped")
        let line = twice["statusLine"] as! [String: Any]
        precondition(line["command"] as! String == "'/Moved/Termik.app/Contents/Resources/hooks/termik-statusline' 'bash ~/.claude/status.sh'")
        precondition(line["padding"] as? Int == 0, "statusLine options kept")
        precondition(ClaudeHooks.merge([:], dir: "/T")["statusLine"].map { ($0 as! [String: Any])["command"] as! String } == "'/T/termik-statusline'")
        print("ok")
    }
}
