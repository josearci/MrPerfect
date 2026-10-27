import AppKit
import Carbon.HIToolbox

/// Grammarly-style button at the start of any highlighted text (yours or someone else's). Clicking it opens the review panel.
/// Detection is Accessibility-only (no simulated ⌘C), so it never touches the clipboard.
@MainActor
enum SelectionButton {
    nonisolated static let size: CGFloat = 20
    static var check: Task<Void, Never>?
    static var downAt = NSPoint.zero  // where the last mouse press started, to recognise a selecting drag

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "selectionButton") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "selectionButton"); if !newValue { hide() } }
    }

    static let panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let b = FirstClickButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        b.layer?.cornerRadius = size / 2
        b.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Improve with MrPerfect")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        b.contentTintColor = .white
        b.toolTip = "Improve with MrPerfect (⌃⌥R)"
        b.target = AppDelegate.shared
        b.action = #selector(AppDelegate.menuTrigger)
        p.contentView = b
        return p
    }()

    static func start() {
        // Global monitors never see clicks on our own windows, so clicking the button doesn't hide it first.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { e in
            MainActor.assumeIsolated { selectionMayHaveChanged(e) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .scrollWheel]) { e in
            MainActor.assumeIsolated {
                if e.type == .leftMouseDown { downAt = NSEvent.mouseLocation }
                hide()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { hide() } }
    }

    static func hide() {
        check?.cancel()
        panel.orderOut(nil)
    }

    static func selectionMayHaveChanged(_ e: NSEvent) {
        // Keyboard selections come from ⇧+arrows or ⌘A; plain typing can't select anything.
        if e.type == .keyUp, e.modifierFlags.isDisjoint(with: [.shift, .command]) { return }
        guard enabled, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, app != .current else { return }
        let up = NSEvent.mouseLocation, down = downAt
        let clicks = e.type == .leftMouseUp ? e.clickCount : 0
        check?.cancel()
        check = Task {
            try? await Task.sleep(for: .milliseconds(120))  // let the app finish updating its selection
            guard !Task.isCancelled else { return }
            let frame: NSRect
            if let sel = Selection.current(pid: app.processIdentifier) {
                guard sel.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
                frame = sel.first.map { buttonFrame(forFirstCharacter: $0, primaryHeight: NSScreen.screens[0].frame.height) }
                    ?? NSRect(x: up.x + 8, y: up.y - size - 8, width: size, height: size)
            } else {
                // The app reports no selection at all (WhatsApp). Guess from the gesture; clicking reads via ⌘C.
                // ponytail: can still misfire on drags that aren't text (e.g. moving a window by its title bar)
                guard clicks > 0, app.bundleIdentifier != "com.apple.finder",
                      let guess = guessedFrame(down: down, up: up, clicks: clicks),
                      !ignoredRoles.contains(roleAt(down) ?? "") else { return }
                frame = guess
            }
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
        }
    }

    /// Things you drag or double-click that are never text. Not buttons, cells or lists: chat apps build message
    /// bubbles from those.
    static let ignoredRoles: Set<String> = [
        "AXScrollBar", "AXSplitter", "AXSlider", "AXValueIndicator", "AXToolbar", "AXMenuBar", "AXMenuBarItem",
        "AXTabGroup", "AXRadioButton", "AXCheckBox",
    ]

    static func roleAt(_ p: NSPoint) -> String? {
        var el: AXUIElement?
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(NSScreen.screens[0].frame.height - p.y), &el) == .success,
              let el else { return nil }
        return Selection.attribute(el, kAXRoleAttribute) as? String
    }

    /// A drag of 10pt or more puts the button left of where the selection starts (the higher point, or the left one on
    /// the same line); a double/triple-click puts it just under the click. A plain click isn't a selection: nil.
    nonisolated static func guessedFrame(down: NSPoint, up: NSPoint, clicks: Int) -> NSRect? {
        if hypot(up.x - down.x, up.y - down.y) >= 10 {
            let start = abs(up.y - down.y) > 8 ? (up.y > down.y ? up : down) : (up.x < down.x ? up : down)
            return NSRect(x: start.x - size - 4, y: start.y - size / 2, width: size, height: size)
        }
        guard clicks >= 2 else { return nil }
        return NSRect(x: up.x - size / 2, y: up.y - size - 10, width: size, height: size)
    }

    /// Left of the first selected character, vertically centred on its line. `rect` is in AX coordinates
    /// (top-left origin on the primary screen); the result is in Cocoa coordinates (bottom-left origin).
    nonisolated static func buttonFrame(forFirstCharacter rect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: rect.minX - size - 4, y: primaryHeight - rect.midY - size / 2, width: size, height: size)
    }
}

final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }  // our app is never active; act on the first click
}
