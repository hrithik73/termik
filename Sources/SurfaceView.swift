import AppKit
import GhosttyKit

/// One libghostty terminal surface. Ghostty attaches its Metal layer to this view.
/// Keyboard and IME handling is adapted from Ghostty's SurfaceView_AppKit.swift (MIT).
/// ponytail: no drag-and-drop, quicklook, services menu or accessibility text; port from Ghostty when wanted.
final class SurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    weak var tab: Tab?
    var cellSize = CGSize(width: 8, height: 16)

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var tracking: NSTrackingArea?

    /// `inherit`: the surface being split, so the new pane gets its cwd and font size.
    init(tab: Tab, cwd: String, inherit: ghostty_surface_t? = nil) {
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var cfg = inherit.map { ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_SPLIT) } ?? ghostty_surface_config_new()
        let cwd = cfg.working_directory.map { String(cString: $0) } ?? cwd
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        surface = cwd.withCString { ptr in
            cfg.working_directory = ptr
            return ghostty_surface_new(Ghostty.shared.app, &cfg)
        }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func from(_ userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
        userdata.map { Unmanaged<SurfaceView>.fromOpaque($0).takeUnretainedValue() }
    }

    func close() {
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        removeFromSuperview()
    }

    // MARK: Size, scale, focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, true) }
        if tab?.focused !== self { tab?.focused = self }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface, newSize.width > 0, newSize.height > 0 else { return }
        let px = convertToBacking(newSize)
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let window, frame.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        ghostty_surface_set_size(surface, UInt32(fb.width), UInt32(fb.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, window != nil)
        if window != nil { viewDidChangeBackingProperties() }
    }

    func setCursor(_ shape: ghostty_action_mouse_shape_e) {
        let cursor: NSCursor = switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        default: .arrow
        }
        cursor.set()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    private func button(_ state: ghostty_input_mouse_state_e, _ b: ghostty_input_mouse_button_e, _ e: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, b, Ghostty.mods(e.modifierFlags))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        _ = button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, e)
    }
    override func mouseUp(with e: NSEvent) { _ = button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, e) }
    override func otherMouseDown(with e: NSEvent) { _ = button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, e) }
    override func otherMouseUp(with e: NSEvent) { _ = button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, e) }
    override func rightMouseDown(with e: NSEvent) {
        if !button(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, e) { super.rightMouseDown(with: e) }
    }
    override func rightMouseUp(with e: NSEvent) {
        if !button(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, e) { super.rightMouseUp(with: e) }
    }

    override func mouseMoved(with e: NSEvent) {
        guard let surface else { return }
        let p = convert(e.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, frame.height - p.y, Ghostty.mods(e.modifierFlags))
    }
    override func mouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func otherMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
    override func mouseEntered(with e: NSEvent) { mouseMoved(with: e) }
    override func mouseExited(with e: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Ghostty.mods(e.modifierFlags))
    }

    override func scrollWheel(with e: NSEvent) {
        guard let surface else { return }
        var x = e.scrollingDeltaX, y = e.scrollingDeltaY
        let precise = e.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        // Packed scroll mods (src/input/mouse.zig): bit 0 = precision, bits 1-3 = momentum phase.
        let momentum: Int32 = switch e.momentumPhase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }

        // Honor configs like macos-option-as-alt by translating with Ghostty's mods.
        let ghosttyFlags = Ghostty.flags(ghostty_surface_key_translation_mods(surface, Ghostty.mods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if ghosttyFlags.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Reusing the original event when unchanged matters for Korean input.
        let translationEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedBefore = markedText.length > 0
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedBefore)
        let composing = markedText.length > 0 || markedBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isControl(text, composing: composing) {
                if markedBefore {
                    _ = sendText(action, text)
                } else {
                    _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else if !Self.isControl(event.characters, composing: composing) {
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: Ghostty.characters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        let pressed = Ghostty.mods(event.modifierFlags).rawValue & mod != 0
        _ = keyAction(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// Ghostty keybinds (cmd+c, cmd+t, …) must reach Ghostty before the menu does.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }

        var ev = Ghostty.keyEvent(event, GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key_is_binding(surface, ev, &flags)
        }
        if isBinding { keyDown(with: event); return true }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r" where event.modifierFlags.contains(.control):
            equivalent = "\r"
        case "/" where event.modifierFlags.contains(.control) && event.modifierFlags.isDisjoint(with: [.shift, .command, .option]):
            equivalent = "_"  // C-/ beeps on macOS; send C-_ like Ghostty
        default:
            // Let the menu try first; if nothing handles it, doCommand re-sends it here.
            guard event.timestamp != 0, !event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
            } else {
                lastPerformKeyEvent = event.timestamp
                return false
            }
        }
        if let e = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                    timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                    characters: equivalent, charactersIgnoringModifiers: equivalent,
                                    isARepeat: event.isARepeat, keyCode: event.keyCode) {
            keyDown(with: e)
        }
        return true
    }

    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var ev = Ghostty.keyEvent(event, action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        guard let text, !text.isEmpty, (text.unicodeScalars.first?.value ?? 0) >= 0x20 else {
            return ghostty_surface_key(surface, ev)
        }
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(surface, ev)
        }
    }

    /// Committed IME/dictation text goes in as typed input, never as a paste.
    private func sendText(_ action: ghostty_input_action_e, _ text: String) -> Bool {
        guard let surface else { return false }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            ev.text = ptr
            return ghostty_surface_key(surface, ev)
        }
    }

    private static func isControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let s = text?.unicodeScalars, s.count == 1 else { return false }
        return s.first!.value < 0x20
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let s = markedText.string
            s.withCString { ghostty_surface_preedit(surface, $0, UInt(s.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange() }
    func selectedRange() -> NSRange { NSRange() }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil { keyTextAccumulator?.append(chars); return }
        if !chars.isEmpty { _ = sendText(GHOSTTY_ACTION_PRESS, chars) }
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let rect = NSRect(x: x, y: frame.height - y, width: range.length == 0 ? 0 : w, height: max(h, Double(cellSize.height)))
        return window?.convertToScreen(convert(rect, to: nil)) ?? rect
    }

    // MARK: Menu actions routed to Ghostty bindings

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "d")
        menu.addItem(withTitle: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "D")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Pane", action: #selector(closePane(_:)), keyEquivalent: "w")
        return menu
    }

    @IBAction func splitRight(_ sender: Any?) { binding("new_split:right") }
    @IBAction func splitDown(_ sender: Any?) { binding("new_split:down") }
    @IBAction func closePane(_ sender: Any?) { binding("close_surface") }

    @IBAction func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @IBAction func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    @IBAction override func selectAll(_ sender: Any?) { binding("select_all") }

    func binding(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }
}
