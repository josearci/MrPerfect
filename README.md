# MrPerfect

A menu bar app for macOS. Select text in any app, then click the small round button that appears at the start of the selection (any highlighted text: your own drafts or a message someone sent you) or press **⌃⌥R**. Choose an action, check the rewrite, and then **Replace** or **Copy** it. Nothing in the other app changes until you press Replace.

```
⌃⌥R ─▶ read selection ─▶ menu: ↩ Improve prompt · 2 Improve message · 3 Translate · 4 Modify
        (Accessibility,            │
         ⌘C fallback)              ▼
                         Claude API  or  Gemma (Ollama on `gpu`, via SSH tunnel)
                                   │
                                   ▼
                  editable result ─▶ ⌘↩ Replace (re-checks selection, pastes)
                                  └▶ ⇧⌘C Copy  /  esc Cancel
```

## Setup

Requirements: macOS 14+, Xcode (for `swift`), and at least one provider: a Claude API key, or a machine running [Ollama](https://ollama.com) with a Gemma model that you can reach over SSH.

```bash
./build.sh
```

This builds a release binary, wraps it in `~/Applications/MrPerfect.app`, signs it with your Apple Development identity (ad-hoc if you have none) and launches it. Afterwards:

1. **Accessibility:** macOS asks the first time. Open System Settings → Privacy & Security → Accessibility and turn on MrPerfect. If the panel says it still needs access, quit the app and open it again.
2. **Claude key:** click the menu bar icon (✨ wand) → *Set Claude API Key…*. The key goes into your login Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). It is never written to disk in plain text or included in iCloud sync.
3. **Provider:** use the menu bar icon to choose between *Use Claude* and *Use Gemma*. The choice applies to the next ⌃⌥R.
4. Optional: *Launch at Login* in the same menu.

Run the tests with `swift test`.

### Settings with no UI (`defaults write com.josearci.MrPerfect <key> <value>`)

| key | default | notes |
|---|---|---|
| `claudeModel` | `claude-opus-5-5` | `claude-haiku-5-5` is faster and far cheaper; `claude-sonnet-5-5` is in between |
| `gemmaModel` | `gemma4:12b` | fits fully in a 12 GB GPU; `gemma4:26b` didn't and was far slower in testing |
| `gemmaSSHHost` | `gpu` | the `~/.ssh/config` host alias of the machine running Ollama |

## Translate

**Translate** always goes in one direction, chosen by the selected text: Spanish becomes English, and anything else becomes Spanish. The language is detected on the Mac with Apple's NaturalLanguage framework (limited to English vs. Spanish), so the menu already says *Translate to English* or *Translate to Spanish* before you pick it. The model is told to output only the translation: it never answers or follows the text, even if the text is a question or a command, and it keeps formatting, names, numbers, links and code as they are. The shortcut is **3**.

## Modify with instructions

Press **4** and type what you want changed, for example "more formal", "add that it's at 3 pm in room B" or "two sentences max", or paste notes, details or a ticket description to work in. The box grows with what you type or paste; ↩ adds a new line and **⌘↩** (or **Apply**) runs it. When you paste material rather than a request, the text is rewritten to include the relevant details in its own voice, not pasted together. The model applies only that change and keeps everything else (meaning, tone, language, formatting, names, numbers, links). The instruction is sent separately from the text, so a command that appears inside the selected text is edited like any other text and never followed. ↻ on the result re-runs the same instruction.

## Providers

### Claude API
The app sends a direct `POST https://api.anthropic.com/v1/messages` request with `anthropic-version: 2026-10-21` and `output_config.effort: "low"` (a rewrite doesn't need deep reasoning, and low effort keeps latency down). It also sends `fallbacks: "default"`, so a safety-classifier false positive is retried on a fallback model on Anthropic's side instead of failing. Haiku doesn't accept that field, so it's left out for Haiku. Text you rewrite with Claude goes to Anthropic.

### Gemma over SSH
Gemma runs under Ollama on another machine, reached through an SSH host alias (`gpu` by default). **Plain SSH access isn't enough by itself:** Ollama listens only on `127.0.0.1:11434` by default, so the Mac can't reach it directly. The app handles this itself:

- On the first Gemma request it starts `ssh -N -L 11435:127.0.0.1:11434 gpu`, a background SSH tunnel that forwards a port on the Mac to Ollama on the box. If your SSH config wakes the machine first (for example a `Match exec` that sends Wake-on-LAN), the app waits up to 150 s for it. The tunnel is stopped when the app quits and restarted if it drops.
- When the panel opens with Gemma selected, the app opens the tunnel and loads the model while you're still choosing an action. With the model loaded, a rewrite took **0.5–2 s**. Loading it from scratch takes ~12 s, and Ollama keeps it loaded for 30 min.
- It uses `BatchMode=yes`, so your SSH key has to work without a password prompt (check with `ssh -o BatchMode=yes gpu true`).
- macOS asks once for **Local Network** access for MrPerfect; allow it, or the tunnel can't reach the machine.

Why a tunnel rather than `OLLAMA_HOST=0.0.0.0` on the GPU machine: Ollama has no authentication, so binding it to the LAN lets any device on your network use it. The tunnel is encrypted and authenticated with your existing SSH key, and nothing changes on the box. Text sent to Gemma stays on your LAN.

Optional, on the GPU machine: `sudo systemctl edit ollama` → `Environment="OLLAMA_KEEP_ALIVE=24h"` keeps the model loaded longer.

## Architecture choices

| Concern | Choice | Why |
|---|---|---|
| App form | Native Swift/AppKit menu bar app (`LSUIElement`), SwiftUI panel | Low memory use. Accessibility, Carbon hotkeys and the Keychain are all native APIs. No Electron, no dependencies. |
| Trigger | Grammarly-style button plus a global hotkey (Carbon `RegisterEventHotKey`) | After a mouse-up or a keyboard selection, the app asks the focused element for its selection through Accessibility only, never ⌘C, so the clipboard is untouched. Text fields report a character range; web content (Chrome, Safari, Mail, Electron apps like Slack) reports a text-marker range, and Chrome/Electron get `AXManualAccessibility` turned on so they expose it. If at least 3 characters are highlighted, editable or not, a 20 pt button appears at the start of the selection. For read-only text (a message you received) the result offers **Copy** as its only action. The button doesn't take focus from your app; your next click, keypress, scroll or app switch hides it, and it can be turned off in the menu. |
| Reading the selection | Accessibility `kAXSelectedTextAttribute` first, simulated ⌘C as a fallback | AX works in native apps without touching the clipboard. Chrome and Electron apps often don't expose it over AX, so they need ⌘C. |
| Replacing | Re-read the selection, and if it still matches, paste with ⌘V, then restore your clipboard after 1 s | Writing through AX silently does nothing in many apps. Pasting works everywhere. The re-check ensures it never pastes over text you didn't approve. |
| Panel | Non-activating floating `NSPanel` | Keystrokes go to the panel but the source app stays active, so its selection is still there when you press Replace. |
| Credentials | Keychain for the Claude key; your SSH key for Gemma | No plain-text secrets anywhere. |
| Sandbox | None (not possible) | The App Sandbox blocks Accessibility control of other apps and starting `ssh`. This means no Mac App Store. |

### Privacy and safety
- The app keeps no logs and no history. Text exists only in memory while the panel is open.
- Secure input (password fields) is detected, and the app refuses to read it.
- The selected text is wrapped in `<text>` tags, and the system prompts say it is content to edit, never instructions. This keeps "Improve prompt" from *answering* your prompt.
- The clipboard is saved before each ⌘C/⌘V and restored afterwards. MrPerfect's own paste is marked `org.nspasteboard.TransientType` so clipboard managers skip it.

## Limitations
- **Apps that hide their text (WhatsApp):** WhatsApp doesn't share message text or selections with other apps, so MrPerfect guesses from the gesture instead: after a drag or a double/triple-click, the button appears where the selection started. Clicking it reads the text with ⌘C and restores your clipboard. Because the app can't say whether the text is editable, Copy is the default (⌘↩) and Replace is secondary. A drag that isn't a text selection (for example moving a window by its title bar) can occasionally show a stray button; your next click hides it.
- **Fallback-copy apps:** in apps that only work with the ⌘C fallback (some Electron apps, Chrome pages), clipboard managers may briefly record your selection. VS Code copies the *current line* when nothing is selected. You'll still see that text before anything is replaced.
- **Apps that block pasting:** some terminals and remote-desktop or VM windows refuse or change synthetic ⌘V. Use **Copy** there.
- **Rebuild signing:** a rebuild signed with a different identity, or ad-hoc, makes macOS ask for Accessibility again. `build.sh` uses your Apple Development certificate so the grant survives rebuilds.
- **Fixed hotkey:** ⌃⌥R is hard-coded. If another app already uses it, Console logs a warning.
- **Panel position on web pages:** Chrome reports a selection's text but not its position, so there the panel opens at the mouse instead of under the text.

## Phased plan

1. **Phase 1 (done):** hotkey and selection button → four actions → editable review → Replace/Copy. Claude and Gemma, switching from the menu bar, Keychain, the SSH tunnel with model pre-loading, launch at login, unit tests for parsing and output cleanup.
2. **Phase 2, daily-driver polish:** stream tokens into the editor (lower perceived latency on Claude). Show a word-level diff of the original and the rewrite. A settings window with a hotkey recorder and model fields. Saved custom actions (a name plus a system prompt).
3. **Phase 3, smarter triggering:** the selection button is done, including read-only text and apps that hide their text. Still to do: a Services-menu entry, and the panel position on web pages.
4. **Phase 4, robustness and distribution:** fall back to the other provider when the GPU box is unreachable (with a visible notice, since the privacy level changes). Retry with backoff on 429/529. Notarize with a Developer ID for use on other Macs. Auto-update (Sparkle).

## Assumptions
- macOS 14+ on Apple Silicon. Built for personal use: you build it yourself, with no notarization or App Store.
- The Gemma machine is on your local network. Away from it, Gemma is unreachable unless you add Tailscale or a VPN and point `gemmaSSHHost` at it.
- Defaulting to Opus 5.5 at low effort favours quality. If latency or cost matters more to you, switch to `claude-haiku-5-5`.
