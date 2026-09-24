// M2: clicks, typing, and the accessibility tree.
// Coordinates arrive as screenshot pixels (origin top-left of that display)
// and are converted here to CGEvent points (origin top-left of the primary display).
// Headless runs pass allowInput: false so a self-test cannot post events.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum Control {
    private static let lock = NSLock()
    private static var settingsApproved = false

    static func toolDefs() -> [[String: Any]] {
        [
            tool("click", "Click a point. x and y are pixels in a screenshot from the screenshot tool, origin top-left of that display.", [
                "x": num("Pixel x"),
                "y": num("Pixel y"),
                "button": str("left, right, or middle. Default left."),
                "count": num("1 is a single click, 2 is a double click. Default 1."),
                "display": num("1-based display index from screenshot. Default 1."),
            ], required: ["x", "y"]),
            tool("type_text", "Type text into whatever is focused. Asks first if the front app is System Settings.", [
                "text": str("Characters to type"),
            ], required: ["text"]),
            tool("key", "Press a key combination such as return, escape, cmd+l, or cmd+shift+a.", [
                "combo": str("Key combo"),
            ], required: ["combo"]),
            tool("scroll", "Scroll at a screenshot pixel. Positive dy scrolls up.", [
                "x": num("Pixel x"),
                "y": num("Pixel y"),
                "dy": num("Vertical amount. Positive scrolls up."),
                "dx": num("Horizontal amount. Default 0."),
                "display": num("1-based display index. Default 1."),
            ], required: ["x", "y", "dy"]),
            tool("ax_tree", "Read the accessibility tree of the focused window. Trimmed. Does not click.", [
                "app": str("App name. Omit for the frontmost app."),
            ], required: []),
        ]
    }

    static func perform(_ name: String, _ args: [String: Any], confirm: (String, String) -> Bool, allowInput: Bool) -> ToolResult? {
        switch name {
        case "click", "type_text", "key", "scroll":
            guard allowInput else {
                log("tool \(name) decision=deny headless")
                return ToolResult(text: "Denied. GUI input is off in this headless run.", isError: true)
            }
            guard guardSettings(confirm) else {
                log("tool \(name) decision=deny settings")
                return ToolResult(text: "Denied. The setting was not changed.", isError: true)
            }
            switch name {
            case "click": return click(args)
            case "type_text": return typeText(args)
            case "key": return pressKey(args)
            default: return scroll(args)
            }
        case "ax_tree":
            return axTree(args)
        default:
            return nil
        }
    }

    /// Top-left pixel of the primary display maps to that display's top-left in CGEvent space.
    static func cgPoint(pixelX: Double, pixelY: Double, displayIndex: Int) -> CGPoint? {
        let ordered = orderedScreens()
        guard displayIndex >= 1, displayIndex <= ordered.count else { return nil }
        let screen = ordered[displayIndex - 1]
        let scale = max(screen.backingScaleFactor, 1)
        let appKitX = screen.frame.minX + pixelX / scale
        let appKitY = screen.frame.maxY - pixelY / scale
        let primary = NSScreen.screens.first ?? screen
        return CGPoint(x: appKitX, y: primary.frame.maxY - appKitY)
    }

    static func orderedScreens() -> [NSScreen] {
        let primary = NSScreen.screens.first
        return NSScreen.screens.sorted { a, b in
            if a == primary { return true }
            if b == primary { return false }
            return a.frame.minX < b.frame.minX
        }
    }

    /// Nil when the top-left pixel of display 1 lands on the primary display's top-left.
    static func coordinateCheck() -> String? {
        guard let primary = NSScreen.screens.first else { return nil }
        guard let p = cgPoint(pixelX: 0, pixelY: 0, displayIndex: 1) else { return "no point for display 1" }
        if abs(p.x - primary.frame.minX) > 0.6 || abs(p.y) > 0.6 {
            return "top-left mapped to \(p), expected (\(primary.frame.minX), 0)"
        }
        return nil
    }

    // MARK: actions

    /// The menu-bar app reports the real frontmost app. This process often sees loginwindow.
    static func frontApp(named: String? = nil) -> (name: String, bundle: String, pid: pid_t)? {
        var fields: [String: Any] = [:]
        if let named, !named.isEmpty { fields["name"] = named }
        if let reply = AgentSocket.call(op: "frontmost", fields: fields, timeout: 2),
           (reply["ok"] as? Bool) == true {
            let pidNum = (reply["pid"] as? NSNumber)?.int32Value ?? 0
            if pidNum > 0 {
                return (reply["name"] as? String ?? "", reply["bundle"] as? String ?? "", pidNum)
            }
        }
        let running = NSWorkspace.shared.runningApplications
        let app: NSRunningApplication?
        if let named, !named.isEmpty {
            app = running.first {
                $0.localizedName?.caseInsensitiveCompare(named) == .orderedSame
                    || $0.bundleIdentifier?.caseInsensitiveCompare(named) == .orderedSame
            }
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app, app.processIdentifier > 0 else { return nil }
        return (app.localizedName ?? "", app.bundleIdentifier ?? "", app.processIdentifier)
    }

    private static func guardSettings(_ confirm: (String, String) -> Bool) -> Bool {
        let front = frontApp()
        let name = (front?.name ?? "").lowercased()
        let bundle = front?.bundle ?? ""
        let settings = name.contains("system settings") || name.contains("system preferences") || bundle == "com.apple.systempreferences"
        if !settings { return true }
        lock.lock()
        let already = settingsApproved
        lock.unlock()
        if already { return true }
        let ok = confirm("Change this setting?", name)
        if ok { lock.lock(); settingsApproved = true; lock.unlock() }
        return ok
    }

    private static func requireTrusted() -> String? {
        AXIsProcessTrusted() ? nil : "Accessibility permission is off for Remote. Turn it on in Settings, then try again."
    }

    private static func click(_ args: [String: Any]) -> ToolResult {
        if let problem = requireTrusted() { return ToolResult(text: problem, isError: true) }
        guard let x = number(args["x"]), let y = number(args["y"]) else {
            return ToolResult(text: "Need x and y", isError: true)
        }
        let display = Int(number(args["display"]) ?? 1)
        let count = max(1, min(3, Int(number(args["count"]) ?? 1)))
        let button = (args["button"] as? String ?? "left").lowercased()
        guard let point = cgPoint(pixelX: x, pixelY: y, displayIndex: display) else {
            return ToolResult(text: "No display \(display)", isError: true)
        }
        log("tool click \(Int(point.x)),\(Int(point.y)) \(button) x\(count) decision=allow")
        let src = CGEventSource(stateID: .hidSystemState)
        let down: CGEventType
        let up: CGEventType
        let btn: CGMouseButton
        switch button {
        case "right": (down, up, btn) = (.rightMouseDown, .rightMouseUp, .right)
        case "middle", "center": (down, up, btn) = (.otherMouseDown, .otherMouseUp, .center)
        default: (down, up, btn) = (.leftMouseDown, .leftMouseUp, .left)
        }
        for i in 1...count {
            guard let d = CGEvent(mouseEventSource: src, mouseType: down, mouseCursorPosition: point, mouseButton: btn),
                  let u = CGEvent(mouseEventSource: src, mouseType: up, mouseCursorPosition: point, mouseButton: btn) else {
                return ToolResult(text: "Could not build the click", isError: true)
            }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            d.post(tap: .cghidEventTap)
            usleep(20_000)
            u.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        return ToolResult(text: "Clicked \(button) at \(Int(point.x)), \(Int(point.y))", isError: false)
    }

    private static func typeText(_ args: [String: Any]) -> ToolResult {
        if let problem = requireTrusted() { return ToolResult(text: problem, isError: true) }
        let text = args["text"] as? String ?? ""
        guard !text.isEmpty else { return ToolResult(text: "Missing text", isError: true) }
        log("tool type_text \(text.prefix(40)) decision=allow")
        let src = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let end = min(i + 12, units.count)
            let slice = Array(units[i..<end])
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
                return ToolResult(text: "Could not type", isError: true)
            }
            slice.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: base)
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: base)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(8_000)
            i = end
        }
        return ToolResult(text: "Typed \(text.count) characters", isError: false)
    }

    private static func pressKey(_ args: [String: Any]) -> ToolResult {
        if let problem = requireTrusted() { return ToolResult(text: problem, isError: true) }
        let combo = (args["combo"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = parseCombo(combo) else { return ToolResult(text: "Unknown key \(combo)", isError: true) }
        log("tool key \(combo) decision=allow")
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: parsed.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: parsed.code, keyDown: false) else {
            return ToolResult(text: "Could not press \(combo)", isError: true)
        }
        down.flags = parsed.flags
        up.flags = parsed.flags
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
        return ToolResult(text: "Pressed \(combo)", isError: false)
    }

    private static func scroll(_ args: [String: Any]) -> ToolResult {
        if let problem = requireTrusted() { return ToolResult(text: problem, isError: true) }
        guard let x = number(args["x"]), let y = number(args["y"]), let dy = number(args["dy"]) else {
            return ToolResult(text: "Need x, y, and dy", isError: true)
        }
        let dx = number(args["dx"]) ?? 0
        let display = Int(number(args["display"]) ?? 1)
        guard let point = cgPoint(pixelX: x, pixelY: y, displayIndex: display) else {
            return ToolResult(text: "No display \(display)", isError: true)
        }
        log("tool scroll \(Int(dx)),\(Int(dy)) decision=allow")
        let src = CGEventSource(stateID: .hidSystemState)
        guard let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
            return ToolResult(text: "Could not scroll", isError: true)
        }
        ev.location = point
        ev.post(tap: .cghidEventTap)
        return ToolResult(text: "Scrolled", isError: false)
    }

    private static func axTree(_ args: [String: Any]) -> ToolResult {
        if let problem = requireTrusted() { return ToolResult(text: problem, isError: true) }
        let wanted = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let app = frontApp(named: wanted) else { return ToolResult(text: "No such app", isError: true) }
        log("tool ax_tree \(app.name) decision=allow")
        let ax = AXUIElementCreateApplication(app.pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else {
            return ToolResult(text: "No focused window for \(app.name.isEmpty ? "the app" : app.name)", isError: true)
        }
        let element = window as! AXUIElement
        var lines = ["\(app.name):"]
        var count = 0
        dump(element, depth: 0, into: &lines, count: &count, limit: 180)
        return ToolResult(text: lines.joined(separator: "\n"), isError: false)
    }

    private static func dump(_ el: AXUIElement, depth: Int, into lines: inout [String], count: inout Int, limit: Int) {
        if count >= limit || depth > 5 { return }
        count += 1
        let role = axString(el, kAXRoleAttribute) ?? "element"
        var bits = [role]
        if let title = axString(el, kAXTitleAttribute), !title.isEmpty { bits.append("\"\(title)\"") }
        if let desc = axString(el, kAXDescriptionAttribute), !desc.isEmpty, desc != axString(el, kAXTitleAttribute) {
            bits.append(desc)
        }
        if let value = axString(el, kAXValueAttribute), !value.isEmpty {
            bits.append("= \(value.count > 80 ? String(value.prefix(80)) + "…" : value)")
        }
        if let pos = axPoint(el), let size = axSize(el) {
            bits.append(String(format: "@%.0f,%.0f %.0fx%.0f", pos.x, pos.y, size.width, size.height))
        }
        lines.append(String(repeating: "  ", count: depth) + bits.joined(separator: " "))
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success else { return }
        let list = children as? [AXUIElement] ?? []
        for child in list.prefix(40) {
            dump(child, depth: depth + 1, into: &lines, count: &count, limit: limit)
            if count >= limit {
                lines.append(String(repeating: "  ", count: depth + 1) + "…")
                return
            }
        }
    }

    private static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axPoint(_ el: AXUIElement) -> CGPoint? { axValue(el, kAXPositionAttribute) }
    private static func axSize(_ el: AXUIElement) -> CGSize? { axValue(el, kAXSizeAttribute) }

    private static func axValue<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let ax = value as! AXValue
        if T.self == CGPoint.self {
            var p = CGPoint.zero
            guard AXValueGetType(ax) == .cgPoint, AXValueGetValue(ax, .cgPoint, &p) else { return nil }
            return p as? T
        }
        var s = CGSize.zero
        guard AXValueGetType(ax) == .cgSize, AXValueGetValue(ax, .cgSize, &s) else { return nil }
        return s as? T
    }

    private struct Combo { var code: CGKeyCode; var flags: CGEventFlags }

    private static func parseCombo(_ combo: String) -> Combo? {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var flags: CGEventFlags = []
        var key: String?
        for p in parts {
            switch p {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default:
                if key != nil { return nil }
                key = p
            }
        }
        guard let key, let code = keyCodes[key] else { return nil }
        return Combo(code: code, flags: flags)
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
            "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
            "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
            "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
            "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
            "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
            "9": CGKeyCode(kVK_ANSI_9),
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
            "esc": CGKeyCode(kVK_Escape), "escape": CGKeyCode(kVK_Escape),
            "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
            "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
            "forwarddelete": CGKeyCode(kVK_ForwardDelete),
            "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
            "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
            "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
            "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
        ]
        return m
    }()
}
