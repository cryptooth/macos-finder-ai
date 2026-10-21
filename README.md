<p align="center">
  <img src="AppIcon.png" width="160" alt="Finder AI icon">
</p>

<h1 align="center">Finder AI</h1>

<p align="center">
  A tiny macOS app that lives in your Finder toolbar. Click it, type what you want in plain language —
  <em>“rename these to 2026-10_Invoice_01.pdf…”</em>, <em>“put every HEIC into a Photos folder”</em> —
  and an AI (Claude or ChatGPT) prepares a plan you can review, apply and undo.
</p>

---

## How it works

1. You click the **Finder AI** button in a Finder window's toolbar.
2. The app reads the folder shown in the front Finder window and any items you have selected.
3. A small floating panel opens. You pick **Claude** or **ChatGPT**, optionally a model, and type a request.
4. Your request, the folder listing and the selection are sent to the AI via its command-line tool
   (`claude` or `codex`). The AI **does not touch your files** — it only returns a JSON plan
   made of two operations: `mkdir` (create folder) and `move` (move / rename).
5. The panel shows the plan as a preview list. Nothing happens until you press **Apply**.
6. Finder AI performs the operations itself with `FileManager` and keeps an undo log, so you can press
   **Undo** to put everything back.

```
Finder toolbar ─▶ Finder AI panel ─▶ claude -p / codex exec (read-only) ─▶ JSON plan
                                                                              │
                         Undo ◀── FileManager (mkdir / move) ◀── Apply ◀── Preview
```

### Safety rules built in

- **No delete operation exists.** If you ask to delete something, the AI explains instead.
- Every path must be **relative to the current folder**; absolute paths, `~` and anything that
  escapes the folder (`..`) are rejected before the preview is even shown.
- **Existing files are never overwritten.** The run stops at the first conflict.
- The whole plan is **validated before** anything is applied, and **every step is undoable**.
  Folders created by the plan are only removed on undo if they are empty again.
- Case-only renames (`a.pdf` → `A.pdf`) work correctly on case-insensitive volumes.
- ChatGPT/Codex runs with `--sandbox read-only`; Claude is asked to plan only.

## Requirements

| Requirement | Notes |
| --- | --- |
| **macOS 13 Ventura or later** | Apple Silicon or Intel. |
| **Xcode Command Line Tools** | Provides `swiftc`, `codesign`, `sips`, `iconutil`. Install with `xcode-select --install` (full Xcode also works). |
| **At least one AI CLI, signed in** | See below. You can install one or both. |

### Claude (Claude Code CLI)

Requires a Claude subscription (Pro / Max / Team / Enterprise) or an Anthropic API key.

```bash
npm install -g @anthropic-ai/claude-code   # or use the native installer from claude.com
claude                                      # run once and sign in
```

### ChatGPT (OpenAI Codex CLI)

Uses your ChatGPT account (Plus / Pro / Team / …) — no API key needed.

```bash
npm install -g @openai/codex    # or: brew install codex
codex login                     # choose “Sign in with ChatGPT”
```

> **`command not found` after installing?** Your npm global `bin` folder isn't on your `PATH`.
> Find it with `echo "$(npm prefix -g)/bin"` and add it to `~/.zshrc`:
>
> ```bash
> echo "export PATH=\"$(npm prefix -g)/bin:\$PATH\"" >> ~/.zshrc && source ~/.zshrc
> ```
>
> Finder AI also asks your login shell (`zsh -lic 'command -v …'`) for the tool's location, so once
> it works in a new Terminal window it will work in the app too.

## Install

```bash
git clone https://github.com/cryptooth/macos-finder-ai.git
cd macos-finder-ai
./build.sh
```

`build.sh` will:

1. Compile `main.swift` with `swiftc` (no Xcode project needed).
2. Turn `AppIcon.png` into `AppIcon.icns`.
3. Write the app's `Info.plist` and sign the bundle ad-hoc.
4. Install it as **`~/Applications/Finder AI.app`** and reveal it in Finder.

### Add the button to the Finder toolbar

1. Open any Finder window.
2. Hold **⌘ Command** and drag `~/Applications/Finder AI.app` onto the toolbar. Release when a gap appears.
3. To remove it later, hold **⌘** and drag the icon off the toolbar.

### Grant permission (first run)

The first time you click the button, macOS asks:
**“Finder AI” wants access to control “Finder”.** Click **Allow**.

This is only used to read the front window's folder and your current selection.
If you dismissed it, enable it in **System Settings → Privacy & Security → Automation → Finder AI → Finder**.

> Because the app is ad-hoc signed, macOS may ask again after each rebuild. That's expected.

## Usage

1. Open a folder in Finder. Optionally select the files you want to work with —
   the panel header shows e.g. `Invoices · 3 selected`.
2. Click the **Finder AI** toolbar button.
3. Choose **Claude** or **ChatGPT**. Optionally type a model name
   (Claude quick picks: `sonnet`, `haiku`, `opus`; leave empty for the CLI's default).
   Your choice is remembered.
4. Type a request and press **Return** (or **Plan**).
5. Review the preview, then press **Apply**. Press **Undo** if you change your mind.

| Key | Action |
| --- | --- |
| Return | Plan / Apply / Close (the highlighted button) |
| Esc | Cancel / Close |

Clicking the toolbar button again while the panel is open refreshes it with the current Finder folder and selection.

### Example requests

- `Rename the selected photos to Trip-2026-001.jpg, Trip-2026-002.jpg … in date order of their names`
- `Create a folder per file extension and move each file into it`
- `Move all PDFs whose name contains "invoice" into Invoices/2026`
- `Make every file name lowercase and replace spaces with dashes`
- `Put the .heic and .png files into a folder called Images`

Requests can be written in any language; the plan summary is returned in English.

## Configuration

Settings live at the top of `main.swift`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `maxListedItems` | `800` | Maximum number of folder entries sent to the AI. |
| `Provider.presets` | `sonnet`, `haiku`, `opus` | Model quick picks shown in the ▾ menu. |
| `Provider.defaultModel` | Claude: `sonnet`, ChatGPT: *(empty)* | Initial model per provider. |

Rebuild with `./build.sh` after changes. The icon source is `assets/AppIcon.svg`; export it to
`AppIcon.png` (1024×1024) to change the icon.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `Command 'claude' / 'codex' not found` | Install the CLI and make sure it runs in a new Terminal window (see the PATH note above). |
| Panel always shows the Desktop | Automation permission is missing — see *Grant permission*. |
| `Could not read Claude's response` | Run `claude -p "hello"` in Terminal to check you're signed in. |
| `ChatGPT (codex) returned an error` | Run `codex exec --skip-git-repo-check "hello"` in Terminal. An old Codex version may not know `--sandbox` / `--output-last-message`; update with `npm i -g @openai/codex`. |
| `Destination already exists` | The plan would overwrite a file. Nothing after that step was applied; press **Undo** to revert earlier steps, or rephrase. |
| Toolbar shows the old icon | Hold ⌘, drag the button off the toolbar, and drag the app on again (Finder caches icons). |
| Compile error | Make sure Command Line Tools are installed and up to date (`xcode-select --install`, `swiftc --version`). |

## Privacy

Finder AI sends the **names** of the items in the current folder (not their contents), the paths of
your selection and your request text to the AI provider you choose, through that provider's official
CLI. Nothing else is collected or sent anywhere.

## Project layout

```
.
├── main.swift          # The whole app (SwiftUI panel + AppKit app delegate)
├── build.sh            # Compile, bundle, icon, sign, install
├── AppIcon.png         # 1024×1024 app icon
└── assets/
    └── AppIcon.svg     # Icon source
```

## Roadmap ideas

- Global keyboard shortcut in addition to the toolbar button
- Copy / duplicate operation
- Recursive listing for nested folders
- Finder Sync / Quick Action integration (right-click menu)
- Notarized release build
