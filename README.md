# Ghostline

A minimal macOS terminal on libghostty (renders and reads config exactly like Ghostty) with:

- **Project-wise tabs**: a sidebar of projects (folders), each with its own tabs.
- **Agents overview**: the title bar counts agents by state across every project (⌘⇧A lists them with
  elapsed time and diff size), a menu-bar item and the Dock badge show how many need you, ⌥⌘J jumps to the next one.
- **Diff review** (⌘⇧R): the tab's changes against `HEAD` (or any ref) in VS Code's diff editor. Edit and ⌘S,
  discard a file, or select lines and ⌘↩ to comment; "Send to Agent" pastes the comments into the agent's prompt.
- **Command palette** (⌘P): jump to any tab or project, paste a snippet, or run an action.
- **Prompt snippets**: Markdown files in `~/.config/ghostline/snippets/` (name = title). ⌥⌘1–9 or the palette
  pastes one into the agent's prompt without sending it.
- **Session resume**: tabs that had Claude running reopen it with `claude --resume <session>` after a relaunch.
- **OSC 7501 program status** ([spec](https://www.superlogical.com/rex/docs/build/program-status)): each tab shows the agent's icon and a state badge (working, blocked, done, error). A notification fires when a background agent needs you.

## Build

```sh
git submodule update --init
./scripts/build-ghosttykit.sh      # needs Zig 0.16 in .tools/ or on PATH, plus Xcode's Metal toolchain
./scripts/fetch-monaco.sh          # VS Code's editor, for the review window
xcodegen generate && open Ghostline.xcodeproj
./scripts/test-status.sh           # OSC 7501 logic self-check
```

`patches/0001-program-status-action.patch` forwards OSC 7501 reports from libghostty to the app as
`GHOSTTY_ACTION_PROGRAM_STATUS` and answers the `OSC 7501;?` probe. Upstream Ghostty drops these reports.

## Keys

| Keys | Action |
|---|---|
| ⌘T / ⌥⌘W | New tab / close tab (in the current project) |
| ⌘D / ⌘⇧D | Split right / split down (new pane inherits the cwd) |
| ⌘W | Close pane (closes the tab when it's the last one) |
| ⌘⌥←↑↓→ · ⌘[ / ⌘] | Move between panes |
| ⌃⌘←↑↓→ · ⌃⌘= | Resize pane · equalize panes |
| ⌘⇧O | Open a folder as a project |
| ⌘1–9 | Go to tab N in the current project |
| ⌃⌘1–9 | Go to project N |
| ⌘⇧A · ⌥⌘J | Agents list · jump to the next agent needing you |
| ⌘⇧R | Review the current tab's changes |
| ⌘P · ⌥⌘1–9 | Command palette · paste snippet N |

Your Ghostty keybinds keep working; `new_tab` and `goto_tab` act on the current project.

## Agent status hooks

To make Claude Code report its status, merge `hooks/claude-settings.json` into `~/.claude/settings.json`.
Any tool can report with `hooks/osc7501 <state> [msg] [kind]`. Other terminals ignore the sequence.

The same file wires `hooks/ghostline-session` to SessionStart/SessionEnd. It records each tab's session id in
`GHOSTLINE_SESSION_FILE` (set by Ghostline) so the tab can resume it; exiting Claude yourself forgets it.
