import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.delegate = AppDelegate.shared
        app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
        app.run()
    }
}

// MARK: - Menu bar + hotkey

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    static let shared = AppDelegate()
    var status: NSStatusItem!
    var panel: NSPanel?
    var session: Session?

    func applicationDidFinishLaunching(_: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "MrPerfect")
        status.menu = NSMenu()
        status.menu?.delegate = self
        NSApp.mainMenu = editMenu()
        Hotkey.register { AppDelegate.shared.trigger() }
        SelectionButton.start()
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func applicationWillTerminate(_: Notification) { Ollama.reset() }

    /// Menu-bar-only apps have no main menu, and without one ⌘C/⌘V/⌘A/⌘Z do nothing in text fields.
    func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Improve Selection  (⌃⌥R)", #selector(menuTrigger)))
        menu.addItem(.separator())
        for p in Provider.allCases {
            let i = item("Use \(p.label)", #selector(pickProvider(_:)))
            i.representedObject = p.rawValue
            i.state = Defaults.provider == p ? .on : .off
            menu.addItem(i)
        }
        menu.addItem(.separator())
        menu.addItem(item(Keychain.apiKey == nil ? "Set Claude API Key…" : "Replace Claude API Key…", #selector(setKey)))
        menu.addItem(item("Set Ollama Address…", #selector(setOllamaAddress)))
        if Keychain.apiKey != nil { menu.addItem(item("Remove Claude API Key", #selector(removeKey))) }
        let button = item("Show Button on Selection", #selector(toggleSelectionButton))
        button.state = SelectionButton.enabled ? .on : .off
        menu.addItem(button)
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if !AXIsProcessTrusted() { menu.addItem(item("Grant Accessibility Access…", #selector(openAXSettings))) }
        menu.addItem(.separator())
        menu.addItem(item("Quit MrPerfect", #selector(NSApplication.terminate(_:)), target: NSApp))
    }

    func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = target ?? self
        return i
    }

    @objc func menuTrigger() { trigger() }
    @objc func pickProvider(_ sender: NSMenuItem) {
        Defaults.provider = Provider(rawValue: sender.representedObject as? String ?? "") ?? .claude
    }
    @objc func removeKey() { Keychain.set(nil) }
    @objc func toggleSelectionButton() { SelectionButton.enabled.toggle() }
    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { try s.status == .enabled ? s.unregister() : s.register() } catch { notice("Launch at Login: \(error.localizedDescription)") }
    }

    // Not an NSAlert: a menu-bar app often can't activate itself on macOS 14+, so an alert never gets the keyboard.
    // The non-activating panel can take keystrokes without activating the app.
    @objc func setKey() {
        let s = Session(original: "", source: nil)
        s.stage = .askKey
        show(s)
    }

    @objc func setOllamaAddress() {
        let s = Session(original: "", source: nil)
        s.addressInput = Defaults.ollamaAddress
        s.stage = .askAddress
        show(s)
    }

    // MARK: Flow

    func trigger() {
        SelectionButton.hide()
        guard let source = NSWorkspace.shared.frontmostApplication, source != .current else { return }
        guard AXIsProcessTrusted() else {
            return notice("MrPerfect needs Accessibility access to read your selection. Menu bar icon → Grant Accessibility Access…")
        }
        guard !IsSecureEventInputEnabled() else {
            return notice("Secure input is on (a password field may be focused), so MrPerfect won't read it.")
        }
        let found = Selection.current(pid: source.processIdentifier, timeout: 1)
        Task {
            guard let text = await Selection.read(from: source),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return notice("Select some text first, then press ⌃⌥R.") }
            show(Session(original: text, source: source, editable: found?.editable), anchor: Selection.anchor(found))
        }
    }

    func notice(_ message: String) {
        let s = Session(original: "", source: nil)
        s.stage = .failed(message)
        show(s)
    }

    /// `anchor` is the selection's extent; without one (the app doesn't report it), the panel hangs under the mouse.
    func show(_ s: Session, anchor: NSRect? = nil) {
        session?.cancel()
        let p = KeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let mouse = NSEvent.mouseLocation
        p.anchor = anchor ?? NSRect(x: mouse.x - 10, y: mouse.y - 10, width: 1, height: 20)
        let host = NSHostingController(rootView: PanelView(s: s))
        host.sizingOptions = .preferredContentSize
        p.contentViewController = host
        p.delegate = self
        s.close = { [weak p] in p?.close() }
        p.reposition()
        p.makeKeyAndOrderFront(nil)
        panel = p
        session = s
        if Defaults.provider == .ollama, s.source != nil { Task { await Ollama.warm() } }
    }

    // Click anywhere else and the panel goes away, without touching the selection.
    func windowDidResignKey(_ n: Notification) {
        if (n.object as? NSPanel) === panel { session?.cancel() }
    }

    // The panel grows when the result arrives; keep it attached to the selection.
    func windowDidResize(_ n: Notification) { (n.object as? KeyPanel)?.reposition() }
}

final class KeyPanel: NSPanel {
    var anchor = NSRect.zero
    override var canBecomeKey: Bool { true }  // so the editor gets keystrokes while the other app stays active

    func reposition() {
        let vf = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main!).visibleFrame
        setFrameOrigin(Self.origin(size: frame.size, anchor: anchor, visible: vf))
    }

    /// Under the selection, left-aligned with the selection button; above it when there's no room below.
    nonisolated static func origin(size: NSSize, anchor: NSRect, visible vf: NSRect, gap: CGFloat = 6) -> NSPoint {
        let x = min(max(anchor.minX, vf.minX + 8), vf.maxX - size.width - 8)
        let below = anchor.minY - gap - size.height
        return NSPoint(x: x, y: below >= vf.minY + 8 ? below : min(anchor.maxY + gap, vf.maxY - size.height))
    }
}

enum Hotkey {
    static var handler: () -> Void = {}
    static var ref: EventHotKeyRef?

    // ponytail: hard-coded ⌃⌥R; add a recorder in Settings if it clashes with an app you use
    static func register(_ h: @escaping () -> Void) {
        handler = h
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { Hotkey.handler() }
            return noErr
        }, 1, &spec, nil, nil)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: OSType(0x4D52_5046), id: 1),
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("MrPerfect: ⌃⌥R is taken by another app (\(status))") }
    }
}

// MARK: - Review panel

@MainActor @Observable
final class Session {
    enum Stage: Equatable { case pick, instruct, working, result, failed(String), askKey, askAddress }
    var stage: Stage = .pick
    var revised = ""
    var keyInput = ""
    var addressInput = ""
    var addressError: String?
    var instruction = ""  // what the user typed for "Modify with instructions"
    var last: Action?
    let original: String
    let source: NSRunningApplication?
    let editable: Bool?  // nil when the app doesn't say (read via ⌘C); Replace stays offered then
    let actions: [Action]
    let provider = Defaults.provider
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored var task: Task<Void, Never>?

    init(original: String, source: NSRunningApplication?, editable: Bool? = nil) {
        self.original = original
        self.source = source
        self.editable = editable
        actions = Action.allCases  // fixed order: ↩ improve prompt, 2 improve message, 3 translate, 4 modify
    }

    /// "Modify with instructions" asks for the instruction first; the others run straight away.
    func pick(_ a: Action) {
        if a == .custom { stage = .instruct } else { run(a) }
    }

    func applyInstruction() {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run(.custom)
    }

    func run(_ a: Action) {
        last = a
        stage = .working
        task?.cancel()
        let instruction = a == .custom ? instruction.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        task = Task {
            do {
                let out = try await provider.rewrite(original, a, instruction: instruction)
                guard !Task.isCancelled else { return }
                revised = fitToSelection(out, original: original)
                stage = .result
            } catch {
                if !Task.isCancelled { stage = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        task?.cancel()
        close()
    }

    func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let status = Keychain.set(key)
        keyInput = ""
        if status == errSecSuccess { return close() }
        stage = .failed("Couldn't save the key to the Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")")
    }

    func saveAddress() {
        let address = addressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OllamaEndpoint.parse(address) != nil else {
            addressError = "Not an address MrPerfect understands. Use one of the forms above."
            return
        }
        Defaults.ollamaAddress = address
        Ollama.reset()
        close()
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(revised, forType: .string)
        close()
    }

    /// Only pastes if the app still has exactly the text we rewrote selected; otherwise leaves it on the clipboard.
    func replace() {
        guard let source else { return }
        let text = revised, original = original
        close()
        Task {
            source.activate()
            try? await Task.sleep(for: .milliseconds(250))
            // ⌘V goes to whatever app is frontmost, so it must still be the source (apps like WhatsApp grab focus).
            guard NSWorkspace.shared.frontmostApplication == source,
                  await Selection.read(from: source) == original,
                  NSWorkspace.shared.frontmostApplication == source
            else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return AppDelegate.shared.notice("The selection or the active app changed, so nothing was replaced. The revised text is on your clipboard.")
            }
            if await !Selection.paste(text, into: source) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                AppDelegate.shared.notice("The selection or the active app changed, so nothing was replaced. The revised text is on your clipboard.")
            }
        }
    }
}

struct PanelView: View {
    @Bindable var s: Session
    @FocusState var keyFocused: Bool
    @FocusState var instructionFocused: Bool

    var body: some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .background { Button("") { s.cancel() }.keyboardShortcut(.cancelAction).opacity(0) }  // esc, in every stage
    }

    @ViewBuilder var content: some View {
        switch s.stage {
        case .pick:
            VStack(spacing: 1) {
                ForEach(Array(s.actions.enumerated()), id: \.element) { i, a in
                    MenuRow(title: a.title(for: s.original), icon: a.icon, hint: i == 0 ? "↩" : "\(i + 1)",
                            shortcut: i == 0 ? .defaultAction : KeyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])) {
                        s.pick(a)
                    }
                }
            }
            .padding(4)
            .frame(width: 250)
        case .instruct:
            // A real text view, not a TextField: pasted notes keep their lines and the box grows with them.
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $s.instruction)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($instructionFocused)
                    .onAppear { instructionFocused = true }
                    .frame(height: textHeight(s.instruction, width: instructWidth - 20 - 12 - 10, maxFraction: 0.4))
                    .overlay(alignment: .topLeading) {
                        if s.instruction.isEmpty {
                            Text("How should it change? You can paste notes or details too.")
                                .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                HStack {
                    Text("e.g. more formal · add that it's at 3 pm · shorter").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Button("Apply") { s.applyInstruction() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(s.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("⌘↩  (↩ adds a new line)")
                }
            }
            .padding(10)
            .frame(width: instructWidth)
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Improving with \(s.provider.short)…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        case .result:
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $s.revised)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: editorHeight)
                HStack(spacing: 6) {
                    Button { if let a = s.last { s.run(a) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Try again")
                    Text(s.provider.short).font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    if s.editable == false {  // someone else's text: nothing to replace
                        Button("Copy") { s.copy() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .help("⌘↩")
                    } else if s.editable == nil {  // the app didn't say (WhatsApp): copying is the safe default
                        Button("Replace") { s.replace() }.help("Paste over the selection")
                        Button("Copy") { s.copy() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .help("⌘↩")
                    } else {
                        Button("Copy") { s.copy() }.keyboardShortcut("c", modifiers: [.command, .shift]).help("⇧⌘C")
                        Button("Replace") { s.replace() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .help("⌘↩")
                    }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(width: cardWidth)
        case .askKey:
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude API key, stored in your login Keychain on this Mac only.").font(.callout)
                SecureField("sk-ant-…", text: $s.keyInput)
                    .focused($keyFocused)
                    .onAppear { keyFocused = true }
                    .onSubmit { s.saveKey() }
                HStack {
                    Spacer()
                    Button("Cancel") { s.cancel() }
                    Button("Save") { s.saveKey() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(s.keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(width: 320)
        case .askAddress:
            VStack(alignment: .leading, spacing: 8) {
                Text("Where does Ollama run?").font(.callout)
                TextField("Leave empty for this Mac", text: $s.addressInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyFocused)
                    .onAppear { keyFocused = true }
                    .onSubmit { s.saveAddress() }
                Grid(alignment: .leading, verticalSpacing: 2) {
                    GridRow { Text("empty").monospaced(); Text("Ollama on this Mac") }
                    GridRow { Text("192.168.1.20").monospaced(); Text("another computer on your network") }
                    GridRow { Text("ssh:gpu").monospaced(); Text("through an SSH host alias") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let e = s.addressError { Text(e).font(.caption).foregroundStyle(.red) }
                HStack {
                    Text("Model: \(Defaults.ollamaModel)").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel") { s.cancel() }
                    Button("Save") { s.saveAddress() }.keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(width: 340)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let a = s.last { Button("Retry") { s.run(a) } }
                    Spacer()
                    Button("Close") { s.cancel() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(width: 300)
        }
    }

    /// Wider for long or structured text (an improved prompt with headings and bullets), compact for a short message.
    var cardWidth: CGFloat {
        s.revised.count > 280 || s.revised.filter { $0 == "\n" }.count > 3 ? 560 : 380
    }

    var editorHeight: CGFloat { textHeight(s.revised, width: cardWidth - 20 - 10, maxFraction: 0.6) }

    /// Pasted notes get the wide box too.
    var instructWidth: CGFloat {
        s.instruction.count > 120 || s.instruction.filter { $0 == "\n" }.count > 1 ? 560 : 380
    }

    /// The text's real wrapped height at `width`, so all of it shows without scrolling, up to `maxFraction` of the
    /// screen; longer text scrolls inside its editor.
    func textHeight(_ text: String, width: CGFloat, maxFraction: CGFloat) -> CGFloat {
        let t = text.isEmpty ? " " : text + (text.hasSuffix("\n") ? " " : "")
        let h = (t as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        ).height
        return min(max(ceil(h) + 12, 44), (NSScreen.main?.visibleFrame.height ?? 900) * maxFraction)
    }
}

struct MenuRow: View {
    let title: String, icon: String, hint: String, shortcut: KeyboardShortcut
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16).foregroundStyle(hover ? Color.white : Color.accentColor)
                Text(title).lineLimit(1)
                Spacer()
                Text(hint).font(.caption).foregroundStyle(hover ? Color.white.opacity(0.8) : Color.secondary)
            }
            .foregroundStyle(hover ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hover ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .onHover { hover = $0 }
    }
}
