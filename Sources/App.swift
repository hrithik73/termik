import AppKit
import GhosttyKit
import SwiftUI
import UserNotifications

@main
struct TermikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store.shared

    var body: some Scene {
        Window("Termik", id: "main") {
            RootView().environment(store)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(store: store) }

        WindowGroup("Review", id: "review", for: UUID.self) { $id in
            ReviewWindow(tab: store.tab(id)).environment(store)
        }
        .defaultSize(width: 1280, height: 820)
        .restorationBehavior(.disabled)  // tab ids don't survive a relaunch

        MenuBarExtra {
            AgentList().environment(store).frame(width: 360)
        } label: {
            let waiting = store.agents.filter { $0.status.top?.state == .blocked }.count
            Image(systemName: waiting > 0 ? "bell.badge.fill" : "terminal")
            if waiting > 0 { Text("\(waiting)") }
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        _ = Ghostty.shared
        NSApp.applicationIconImage = UserDefaults.standard.string(forKey: "appIcon").flatMap(NSImage.init(named:))
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        DispatchQueue.main.async { ClaudeHooks.offer() }
    }
    func applicationDidBecomeActive(_ n: Notification) { ghostty_app_set_focus(Ghostty.shared.app, true) }
    func applicationDidResignActive(_ n: Notification) { ghostty_app_set_focus(Ghostty.shared.app, false) }
    func applicationWillTerminate(_ n: Notification) { Store.shared.save() }
    /// `open -a Termik <dir>` from any terminal opens the folder as a project.
    func application(_ app: NSApplication, open urls: [URL]) {
        for url in urls where url.hasDirectoryPath { Store.shared.open(root: url.path(percentEncoded: false)) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

/// The libghostty app: config, runtime callbacks and action dispatch.
final class Ghostty {
    static let shared = Ghostty()
    let app: ghostty_app_t
    let config: ghostty_config_t

    private init() {
        // Reuse an installed Ghostty.app's resources (terminfo, shell integration, themes).
        if getenv("GHOSTTY_RESOURCES_DIR") == nil,
           let res = Bundle.main.resourceURL?.appending(path: "ghostty").path(percentEncoded: false),
           FileManager.default.fileExists(atPath: res) {
            setenv("GHOSTTY_RESOURCES_DIR", res, 1)
        }
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)

        // Same config files as Ghostty.app, so it looks and behaves the same.
        config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        var rt = ghostty_runtime_config_s()
        rt.supports_selection_clipboard = false
        rt.wakeup_cb = { _ in DispatchQueue.main.async { ghostty_app_tick(Ghostty.shared.app) } }
        rt.action_cb = { _, target, action in Ghostty.handle(target, action) }
        rt.read_clipboard_cb = { ud, _, state, _, _, _ in Ghostty.readClipboard(ud, state) }
        rt.confirm_read_clipboard_cb = { ud, confirm, state, request in Ghostty.confirmClipboard(ud, confirm, state, request) }
        rt.write_clipboard_cb = { _, location, contents, len, confirm in
            // ponytail: OSC 52 writes that need confirmation are dropped; add a prompt if a tool needs them.
            guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let contents else { return }
            for i in 0..<len where String(cString: contents[i].mime) == "text/plain" {
                let text = String(decoding: UnsafeRawBufferPointer(start: contents[i].data, count: contents[i].len), as: UTF8.self)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        rt.close_surface_cb = { ud, needsConfirm in
            let view = SurfaceView.from(ud)
            DispatchQueue.main.async {
                guard let tab = view?.tab else { return }
                guard let view else { return }
                if needsConfirm && !Ghostty.confirm("Close this pane?", "A process is still running in it.") { return }
                tab.closePane(view)
            }
        }
        app = ghostty_app_new(&rt, config)
    }

    // MARK: Actions

    /// Called on the main thread during app tick. C strings live only until this returns.
    static func handle(_ target: ghostty_target_s, _ a: ghostty_action_s) -> Bool {
        let view = target.tag == GHOSTTY_TARGET_SURFACE ? SurfaceView.from(ghostty_surface_userdata(target.target.surface)) : nil
        let tab = view?.tab
        let store = Store.shared

        switch a.tag {
        case GHOSTTY_ACTION_PROGRAM_STATUS:
            if let body = a.action.program_status.body, let r = StatusRecord(body: String(cString: body)) {
                tab?.receive(r)
            }
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            tab?.progressReport(a.action.progress_report)
        case GHOSTTY_ACTION_COMMAND_FINISHED, GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            tab?.status.processEnded()
            return a.tag == GHOSTTY_ACTION_COMMAND_FINISHED
        // Title and cwd follow the focused pane.
        case GHOSTTY_ACTION_SET_TITLE:
            if let t = a.action.set_title.title, tab?.focused.map({ $0 === view }) ?? true { tab?.title = String(cString: t) }
        case GHOSTTY_ACTION_PWD:
            if let p = a.action.pwd.pwd, tab?.focused.map({ $0 === view }) ?? true { tab?.pwd = String(cString: p) }
        case GHOSTTY_ACTION_NEW_SPLIT:
            if let tab, let view { tab.split(view, a.action.new_split) }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            if let view, let next = tab?.neighbor(of: view, a.action.goto_split) { next.window?.makeFirstResponder(next) }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            if let view { tab?.root.find(view)?.resize(a.action.resize_split) }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            tab?.root.equalize()
        case GHOSTTY_ACTION_NEW_TAB:
            store.newTab(in: tab?.project)
        case GHOSTTY_ACTION_NEW_WINDOW:
            store.addProject()
        case GHOSTTY_ACTION_CLOSE_TAB:
            if let tab { store.close(tab) }
        case GHOSTTY_ACTION_GOTO_TAB:
            store.gotoTab(Int(a.action.goto_tab.rawValue))
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursor(a.action.mouse_shape)
        case GHOSTTY_ACTION_CELL_SIZE:
            let s = a.action.cell_size
            let scale = view?.window?.backingScaleFactor ?? 2
            view?.cellSize = CGSize(width: Double(s.width) / scale, height: Double(s.height) / scale)
        case GHOSTTY_ACTION_OPEN_URL:
            let u = a.action.open_url
            if let ptr = u.url,
               let url = URL(string: String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)), as: UTF8.self)) {
                NSWorkspace.shared.open(url)
            }
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = a.action.desktop_notification
            notify(n.title.map { String(cString: $0) } ?? "Termik", n.body.map { String(cString: $0) } ?? "")
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
        case GHOSTTY_ACTION_OPEN_CONFIG:
            // Ghostty's ⌘, reaches the surface before the menu; open Termik's Settings instead of the config file.
            if let menu = NSApp.mainMenu?.items.first?.submenu, let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                menu.performActionForItem(at: i)
            }
        case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
            NSApp.keyWindow?.toggleFullScreen(nil)
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
        default:
            return false
        }
        return true
    }

    // MARK: Clipboard

    private static func readClipboard(_ ud: UnsafeMutableRawPointer?, _ state: UnsafeMutableRawPointer?) -> ghostty_clipboard_read_result_e {
        guard let surface = SurfaceView.from(ud)?.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        guard let text = NSPasteboard.general.string(forType: .string) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, text, state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Unsafe pastes and OSC 52 reads need the user's OK.
    private static func confirmClipboard(_ ud: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
                                         _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
        guard let view = SurfaceView.from(ud), view.surface != nil else { return }
        var text = ""
        if let c = confirm?.pointee, let contents = c.contents {
            for i in 0..<c.contents_len where String(cString: contents[i].mime) == "text/plain" {
                text = String(decoding: UnsafeRawBufferPointer(start: contents[i].data, count: contents[i].len), as: UTF8.self)
            }
        }
        DispatchQueue.main.async {
            guard let surface = view.surface else { return }
            let isPaste = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
            let ok = Ghostty.confirm(isPaste ? "Paste this text?" : "Allow the program to read your clipboard?",
                             isPaste ? String(text.prefix(500)) : "")
            if ok { complete(surface, text, state, confirmed: true) } else { ghostty_surface_deny_clipboard_request(surface, state) }
        }
    }

    private static func complete(_ surface: ghostty_surface_t, _ text: String, _ state: UnsafeMutableRawPointer?, confirmed: Bool) {
        let bytes = Array(text.utf8)
        "text/plain".withCString { mime in
            bytes.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(buf.count, 1)) { data in
                    var content = ghostty_clipboard_content_s(mime: mime, data: data, len: buf.count)
                    var available: UnsafePointer<CChar>? = mime
                    withUnsafePointer(to: &content) { cptr in
                        withUnsafePointer(to: &available) { aptr in
                            var c = ghostty_clipboard_complete_s(contents: cptr, contents_len: 1, available: aptr,
                                                                 available_len: 1, confirmed: confirmed, remember: false)
                            ghostty_surface_complete_clipboard_request(surface, &c, state)
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    /// Ghostty's unfocused-split-fill (falls back to background) and how much of it covers an unfocused pane.
    lazy var unfocusedSplit: (fill: NSColor, alpha: CGFloat) = {
        var opacity = 0.7
        var c = ghostty_config_color_s()
        let get = { (ptr: UnsafeMutableRawPointer, key: String) in ghostty_config_get(self.config, ptr, key, UInt(key.utf8.count)) }
        _ = get(&opacity, "unfocused-split-opacity")
        if !get(&c, "unfocused-split-fill") { _ = get(&c, "background") }
        return (NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1), 1 - opacity)
    }()

    /// Ghostty's background, painted behind each pane's padding so it matches the terminal.
    lazy var background: NSColor = {
        var c = ghostty_config_color_s()
        _ = ghostty_config_get(config, &c, "background", UInt("background".utf8.count))
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }()

    static func confirm(_ title: String, _ info: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    static func flags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { f.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { f.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { f.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { f.insert(.command) }
        return f
    }

    /// Key event without text; callers set `text` inside a withCString scope.
    static func keyEvent(_ e: NSEvent, _ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(e.keyCode)
        ev.mods = mods(e.modifierFlags)
        // Heuristic from Ghostty: control and command never contribute to text.
        ev.consumed_mods = mods((translationMods ?? e.modifierFlags).subtracting([.control, .command]))
        if e.type == .keyDown || e.type == .keyUp, let cp = e.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            ev.unshifted_codepoint = cp.value
        }
        return ev
    }

    /// Text for a key event: control chars are encoded by Ghostty itself, PUA function keys dropped.
    static func characters(_ e: NSEvent) -> String? {
        guard let chars = e.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return e.characters(byApplyingModifiers: e.modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(s.value) { return nil }
        }
        return chars
    }
}
