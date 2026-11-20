<h1 align="center">
  <img src="assets/icon.svg" width="128" alt="Clipy icon"><br>
  Clipy
</h1>

<p align="center">
  A native macOS clipboard manager that pastes <em>exactly</em> what you copied.<br>
  Text · Images · Links tabs · offline smart actions · animated clip logo in the menu bar · opens with ⇧⌘V
</p>

<p align="center">
  <a href="https://github.com/Gokulakrishnxn/Clipy/actions/workflows/ci.yml"><img src="https://github.com/Gokulakrishnxn/Clipy/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/Gokulakrishnxn/Clipy/releases/latest"><img src="https://img.shields.io/github/v/release/Gokulakrishnxn/Clipy?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-blue" alt="Universal">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
</p>

---

## Install

**Homebrew** (recommended):

```sh
brew install --cask gokulakrishnxn/clipy/clipy
```

Always use the full name. Since Homebrew 6, code from a non-official tap must be trusted before it is loaded, and installing by full name trusts just this one cask. Homebrew's own catalog also has an unrelated cask called `clipy` (the original Clipy app), so the full name makes sure you get this one.
Update with `brew upgrade --cask gokulakrishnxn/clipy/clipy`; remove the app and its history with `brew uninstall --zap --cask gokulakrishnxn/clipy/clipy`.

<details>
<summary>Prefer to tap first?</summary>

```sh
brew tap gokulakrishnxn/clipy
brew trust --cask gokulakrishnxn/clipy/clipy   # required on Homebrew ≥ 6
brew install --cask gokulakrishnxn/clipy/clipy
```
</details>

**Direct download:** grab `Clipy-<version>.dmg` from the [latest release](https://github.com/Gokulakrishnxn/Clipy/releases/latest),
drag Clipy to Applications, and open it. Requires **macOS 14 Sonoma** or newer; runs natively on Apple Silicon and Intel.

> **Unsigned builds.** Until the app ships with a Developer ID, macOS may say it "cannot be opened".
> Run `xattr -cr /Applications/Clipy.app` once (the cask does this for you).

On first paste Clipy asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility).
That permission is what lets it press ⌘V in the app you came from; without it, items are still put on the clipboard and you paste manually.

## Why another clipboard manager?

| Problem with most OSS clipboard managers | What Clipy does |
| --- | --- |
| Rich text comes back mangled, Markdown loses its formatting, tables become plain text | Stores **every pasteboard flavour** (`public.utf8-plain-text`, `public.html`, `public.rtf`, `com.apple.iWork.*`, …) byte-for-byte and writes them all back. What you paste is what you copied. |
| SQLite history that eventually corrupts, or memory that grows until the app is restarted | A Rust engine on **redb** (copy-on-write, atomic commits, no WAL) with payloads as immutable **content-addressed files**. Bad rows are dropped, never fatal. Only summaries and small thumbnails stay in memory. |
| Web-view UIs that don't feel like macOS | A real `NSPanel` with vibrancy, stock SwiftUI controls, the system shortcut recorder and About panel. The same construction as Maccy. |

## Why Clipy, if Maccy exists?

[Maccy](https://github.com/p0deje/Maccy) set the standard for what a macOS clipboard manager should feel like, and Clipy keeps that feel: the same kind of non-activating panel, the same keyboard model, every pasteboard flavour preserved. Where Clipy goes further is underneath — the part you notice only when it fails.

| | Maccy | Clipy |
| --- | --- | --- |
| Native panel UI, keyboard-first | ✓ | ✓ |
| Pastes every pasteboard flavour back exactly | ✓ | ✓ |
| History database | SwiftData on SQLite; text and image payloads stored as blobs inside the database file | **redb** — copy-on-write B-tree, every commit atomic, no write-ahead log to lose or replay |
| Payload storage | Inside the SQLite file | **Immutable content-addressed files** (BLAKE3), written `tmp → fsync → rename`, so a payload can never be half-written |
| Database won't open at launch | App stops with a fatal error | **Self-heals**: the file is quarantined aside, a fresh store opens, and the app starts |
| Corrupt record | — | **Isolated**: every row is decoded independently; a bad one is dropped and logged, the rest load |
| Engine | Swift, in-process | **Rust** (`clipper-core`), memory-safe, no garbage collector, called from Swift through UniFFI |
| Engine test-suite | Swift unit + UI tests | 41 Rust unit tests covering ingest, dedup, caps, recovery, search and FFI round-trips — runnable on any OS, in CI on every push |
| Memory footprint by design | Managed by SwiftData | Only row summaries and ≤ 320 px thumbnails stay resident; payloads are read on demand and history is capped by `maxItems` |
| Index size | Grows with payloads | Stays small — the index holds metadata only, so scans, backups and recovery stay fast |
| License | MIT | MIT |

In one sentence: Clipy is a Maccy-style front end on a storage engine designed so that history cannot corrupt, cannot tear, and cannot crash the app — and that design is unit-tested in isolation from macOS.

## Features

- **Menu bar item** – the clip logo's paperclip mark (or the full "clip" wordmark), following light/dark. It gives a little bounce whenever you copy or paste. Left-click opens history; right-click gives Open · Pause Recording · Preferences… · About · Quit.
- **Category tabs** – **All · Text · Images · Links · Files**, each with a live count. Switch with Tab / ⇧Tab or ⌘← / ⌘→; the last tab is remembered.
- **History popup** – search field, one row per item with ⌘1–⌘9 for the first nine, type icons, thumbnails for images, swatches for colours, how long ago each item was copied, optional source-app icons. Links show the domain in bold and the path in grey; pinned items sit under their own heading.
- **Smart actions, fully offline** – each clip gets a small label and one-key actions (⌃1–⌃9), worked out on your Mac with simple rules: no AI, no network, no API key. See [Smart assistant](#smart-assistant).
- **Hover preview** – full content plus *Application · First copy · Last copy · Number of copies · Size · Formats*.
- **Everything copyable** – text, links, colours, images, files and folders (including videos and any other file type, by path), and app-private formats.
- **Exact paste** by default; ⌥⏎ pastes plain text when you want to strip formatting; ⇧⏎ copies without pasting.
- **Pin** items so they survive Clear and never age out.
- **Select several** items with ⌘-click, ⇧-click, ⌘A or the footer's select button, then delete or pin them together. The footer's trash menu clears history, keeping pinned items or including them.
- **Configurable shortcuts** – open (default ⇧⌘V), pin (⌥P), delete (⌥⌫) via the standard macOS recorder.
- **Preferences** – popup position (cursor / status item / active window / centre / last position), menu bar icon and its animation, launch at login, paste-vs-copy, history size, what to store, ignored apps, clear on quit.
- **Privacy** – copies flagged concealed or transient by password managers (`org.nspasteboard.*`) are never recorded; add any app to the ignore list; nothing ever leaves your Mac.

## Smart assistant

The bar under the list shows actions for the selected item; press ⌃1–⌃9 or click one. The same actions are in each row's right-click menu under **Smart Actions**.
A text result is put on the clipboard (and pasted, if "Paste automatically" is on) and is saved as a new history item.

| You copied | Label | Actions |
| --- | --- | --- |
| A GitHub / GitLab / Bitbucket URL or `*.git` | Repo | Open · `git clone …` · Markdown link · Copy domain |
| A URL with `token=`, `api_key=`, `sig=`, … | Token | Open · **Copy without token** |
| A URL with `utm_*`, `fbclid`, `gclid`, … | Tracked | Open · **Clean link** |
| `localhost` / an IP address | Local | Open · Markdown link |
| JSON | JSON | Pretty JSON · Minify JSON |
| `12*7 + (3-1)^2` | `= 88` | Copy result |
| An email address | Email | Compose · Copy domain |
| `#ff8800` | Color | Copy as `rgb()` |
| An existing file path | Path | Reveal in Finder · Open |
| `rm -rf`, `curl … \| sh`, `git push --force`, `DROP TABLE`, … | ⚠ warning | — |
| An API key, GitHub/Slack/AWS token, JWT or private key | Secret (red) | Forget secret |
| Base64 | Base64 | Base64 decode |
| Plain text | — | Trim spaces · Join / sort / dedupe lines · UPPERCASE · lowercase · Title Case · snake_case · camelCase · Base64 encode · URL decode |
| An image | — | Save to Downloads · Copy size |
| Files | — | Reveal in Finder · Open · Copy path · Copy name |

The rules live in [`SmartDetector.swift`](macos/Sources/Clipper/Smart/SmartDetector.swift). The calculator is a small built-in parser, so pasted text is never run as code.

## Keyboard reference (popup open)

| Keys | Action |
| --- | --- |
| ↑ ↓ · ⌘J ⌘K · PgUp PgDn · Home End | Move selection |
| ⏎ | Paste (or copy only, if "Paste automatically" is off) |
| ⇧⏎ | Copy only (inverts the above) |
| ⌥⏎ | Paste without formatting |
| ⌘1 … ⌘9 | Paste the n-th item |
| Tab · ⇧Tab · ⌘← ⌘→ | Next / previous category tab |
| ⌃1 … ⌃9 | Run the n-th smart action for the selection |
| ⌘-click · ⇧-click · ⌘A | Select items · select a range · select all |
| ⌫ (with items selected) | Delete the selected items |
| space (select mode) | Check / uncheck the highlighted item |
| ⌥P | Pin / unpin (all selected items, if any) |
| ⌥⌫ | Delete (all selected items, if any) |
| ⌥⌘⌫ · ⇧⌥⌘⌫ | Clear (keeps pinned) · Clear all (including pinned); also in the footer's trash menu |
| ⌘, | Preferences |
| esc | Clear search, then close |

## Building from source

Requirements: macOS 14+, **Xcode 16 or newer** (the full app, not just the Command Line Tools), [Rust](https://rustup.rs).

```sh
git clone https://github.com/Gokulakrishnxn/Clipy && cd Clipy
scripts/build-macos.sh --install      # build → /Applications/Clipy.app → launch
```

`build-macos.sh` compiles the Rust engine as a static library, generates the Swift bindings with [UniFFI](https://mozilla.github.io/uniffi-rs/),
runs `swift build`, assembles and signs the bundle. Useful flags: `--debug` (fast iteration), `--universal --dmg` (what the release
workflow ships), or `scripts/brew-local.sh` to install your local build through Homebrew via a local tap.

> **Tip for developers.** macOS ties the Accessibility grant to the code signature, and ad-hoc signatures change every build.
> Create a self-signed *Code Signing* certificate in Keychain Access (e.g. `Clipy Dev`) and `export CODESIGN_IDENTITY="Clipy Dev"` so the grant survives rebuilds.

`scripts/gen-icons.sh` rebuilds `AppIcon.icns` from `assets/icon.svg`. It uses ImageMagick when installed, and otherwise macOS's own SVG renderer.

```sh
cargo test --workspace          # engine + FFI tests (run anywhere, including Linux)
scripts/check-macos-on-linux.sh # cross-check the darwin target from a Linux box
```

## How it works

<p align="center">
  <img src="docs/img/architecture.png" width="900" alt="Clipy architecture: Swift/AppKit shell talking to the Rust engine over UniFFI; ClipboardWatcher captures every pasteboard flavour, Paster writes them all back and posts ⌘V; clipper-core persists to redb and BLAKE3 blobs">
</p>

Details, including the reliability design and threading model, are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
Release mechanics are in [docs/RELEASING.md](docs/RELEASING.md).

## Project layout

```
crates/clipper-core     engine: ingest, history, redb store, blob store, search, thumbnails (unit-tested)
crates/clipper-ffi      UniFFI façade exported to Swift (static library)
crates/uniffi-bindgen   the bindings generator binary
macos/                  SwiftPM package: the app (AppKit + SwiftUI)
  Sources/Clipper/Smart   offline smart detector (labels + actions)
  Sources/Clipper/Panel   floating panel, popup positioning, clip logo + menu-bar animation
assets/                 icon.svg (app icon), clip-mark.svg / clip-wordmark.svg (menu-bar icon sources)
packaging/homebrew      the cask (mirrored to Gokulakrishnxn/homebrew-clipy on release)
scripts/                build-macos.sh · brew-local.sh · gen-icons.sh · render_icon.swift · check-macos-on-linux.sh
```

## Status

`0.2.x` — the first native builds. The engine has a full test suite; the app is young and has had limited real-world use.
Please [open an issue](https://github.com/Gokulakrishnxn/Clipy/issues) with the app you were copying from and the *Formats* line from the preview when something pastes wrong.

## Acknowledgements

Clipy is a fork of [kkrishnan90/Clipper4Mac](https://github.com/kkrishnan90/Clipper4Mac), which provides the storage engine and the app's foundation.

The panel behaviour, keyboard model and overall layout follow [Maccy](https://github.com/p0deje/Maccy) (MIT), the reference for what a macOS clipboard manager should feel like.
Global shortcuts use [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) by Sindre Sorhus.

## License

Copyright © 2026 Gokulakrishnan, and © 2026 kkrishnan90 for the original Clipper4Mac code. Released under the [MIT License](LICENSE) — free for personal and commercial use, modification and redistribution.
