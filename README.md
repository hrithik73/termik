# Ghostline

A minimal macOS terminal on libghostty (renders and reads config exactly like Ghostty) with:

- **Project-wise tabs**: a sidebar of projects (folders), each with its own tabs.
- **OSC 7501 program status** ([spec](https://www.superlogical.com/rex/docs/build/program-status)): each tab shows the agent's icon and a state badge (working, blocked, done, error). A notification fires when a background agent needs you.

## Build

```sh
git submodule update --init
./scripts/build-ghosttykit.sh      # needs Zig 0.16 in .tools/ or on PATH, plus Xcode's Metal toolchain
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
| ⌘B | Toggle the sidebar |

Your Ghostty keybinds keep working; `new_tab` and `goto_tab` act on the current project.

## Agent status hooks

To make Claude Code report its status, merge `hooks/claude-settings.json` into `~/.claude/settings.json`.
Any tool can report with `hooks/osc7501 <state> [msg] [kind]`. Other terminals ignore the sequence.
