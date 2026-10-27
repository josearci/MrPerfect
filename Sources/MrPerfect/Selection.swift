import AppKit
import ApplicationServices

/// Reads and replaces the selection in another app. Needs Accessibility permission.
@MainActor
enum Selection {
    /// Accessibility API first (no clipboard touch); falls back to a simulated ⌘C for apps that don't expose it.
    static func read(from app: NSRunningApplication) async -> String? {
        if let s = current(pid: app.processIdentifier, timeout: 1)?.text { return s }
        return await copyViaClipboard()
    }

    struct Found {
        let text: String
        let first: CGRect?   // first character, AX coordinates (top-left origin)
        let all: CGRect?     // whole selection
        let editable: Bool
    }

    /// Whatever is highlighted in the app's focused element, editable or not. Text fields report a character range;
    /// web content (Chrome, Safari, Mail, Electron apps like Slack) reports a text-marker range instead.
    /// `timeout`: the passive button check stays at 0.25s; a click or hotkey can wait for a slow app (a new Chrome
    /// window builds its accessibility tree on the first question).
    static func current(pid: pid_t, timeout: Float = 0.25) -> Found? {
        guard let el = focusedElement(pid: pid, timeout: timeout) else { return nil }
        var settable: DarwinBoolean = false
        let editable = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        if let text = attribute(el, kAXSelectedTextAttribute) as? String, !text.isEmpty {
            let range = selectedRange(el)
            return Found(text: text, first: range.flatMap { bounds(el, CFRange(location: $0.location, length: 1)) },
                         all: range.flatMap { bounds(el, $0) }, editable: editable)
        }
        guard let markers = attribute(el, "AXSelectedTextMarkerRange"),
              let text = parameterized(el, "AXStringForTextMarkerRange", markers) as? String, !text.isEmpty
        else { return nil }
        // ponytail: markers give the whole selection's box; its top-left stands in for the first character
        let all = rect(parameterized(el, "AXBoundsForTextMarkerRange", markers))
        let first = all.map { CGRect(x: $0.minX, y: $0.minY, width: 1, height: min($0.height, 18)) }
        return Found(text: text, first: first, all: all, editable: editable)
    }

    /// Where the review panel hangs: the selection's extent in Cocoa coordinates (see `anchorRect`).
    static func anchor(_ found: Found?) -> NSRect? {
        guard let first = found?.first else { return nil }
        return anchorRect(first: first, all: found?.all ?? first, primaryHeight: NSScreen.screens[0].frame.height)
    }

    /// From the first character's and the whole selection's AX rects (top-left origin) to a Cocoa rect that starts at
    /// the selection button's x and spans from the top of the first line to the bottom of the selection.
    nonisolated static func anchorRect(first: CGRect, all: CGRect, primaryHeight h: CGFloat) -> NSRect {
        let top = h - first.minY, bottom = h - max(first.maxY, all.maxY)
        return NSRect(x: first.minX - SelectionButton.size - 4, y: bottom, width: 1, height: top - bottom)
    }

    static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var range = CFRange()
        guard let v = attribute(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID(),
              AXValueGetValue(v as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func bounds(_ el: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        return AXValueCreate(.cfRange, &range).flatMap { rect(parameterized(el, kAXBoundsForRangeParameterizedAttribute, $0)) }
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        var r = CGRect.zero
        guard let v, CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 0 else { return nil }
        return r
    }

    static func parameterized(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &value) == .success ? value : nil
    }

    static var accessibilityEnabled: Set<pid_t> = []

    static func focusedElement(pid: pid_t, timeout: Float = 0.25) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)  // a hung app must not freeze our main thread for the default 6s
        // Chrome and Electron apps build their accessibility tree lazily, per window; this switch turns it on for
        // the whole app. Other apps ignore it.
        if accessibilityEnabled.insert(pid).inserted {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        guard let focused = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        let el = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(el, timeout)
        return el
    }

    static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func copyViaClipboard() async -> String? {
        await waitForModifierRelease()
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postCommand(key: 0x08)  // kVK_ANSI_C
        for _ in 0..<25 where pb.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pb.changeCount != before else { return nil }  // nothing selected, app didn't copy
        let text = pb.string(forType: .string)
        restore(pb, saved)
        return text
    }

    /// Pastes over the current selection in `app`, then puts the user's clipboard back. Returns false, without
    /// pasting, if another app came to the front: ⌘V always goes to the frontmost app.
    static func paste(_ text: String, into app: NSRunningApplication) async -> Bool {
        await waitForModifierRelease()
        guard NSWorkspace.shared.frontmostApplication == app else { return false }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))  // clipboard managers skip it
        postCommand(key: 0x09)  // kVK_ANSI_V
        // ponytail: fixed 1s before restoring the clipboard; raise it if a slow app pastes the old contents
        try? await Task.sleep(for: .seconds(1))
        restore(pb, saved)
        return true
    }

    static func postCommand(key: CGKeyCode) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    /// The hotkey's ⌃⌥ may still be held; a synthetic ⌘C would arrive as ⌃⌥⌘C.
    static func waitForModifierRelease() async {
        for _ in 0..<50 where !NSEvent.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    static func restore(_ pb: NSPasteboard, _ saved: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        pb.writeObjects(saved.map { types in
            let item = NSPasteboardItem()
            types.forEach { item.setData($1, forType: $0) }
            return item
        })
    }
}
