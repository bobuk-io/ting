# Ting

**A keyboard launcher for macOS.** Hold a leader key, then press a key or a short sequence to open an app, a link or a small tool. Search with **launcha** when you do not remember a shortcut.

![Ting selecta: a keyboard-first menu of apps, links and groups](docs/images/selecta.webp)

[![Latest release](https://img.shields.io/github/v/release/bobuk-io/ting)](https://github.com/bobuk-io/ting/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-222)
[![License: 0BSD](https://img.shields.io/badge/license-0BSD-blue)](LICENSE)

Ting lives in the menu bar. Choose any non-modifier key as your leader; there is no default. For example, press `Home`, then `Space` to open an app, or type a short sequence to follow a group of shortcuts. No search field, Dock or mouse required.

```text
Home  space      →  WezTerm
Home  t  r       →  raycast://extensions/raycast/ai/to-russian
Home  w  d  s    →  https://developer.apple.com/documentation/swiftui
```

Ting is Jamaican patois and London slang for “thing”. Its interface borrows a little from grime and sound-system culture: amber keycaps on graphite, `esc pull up`, `⌫ rewind`.

## Screenshots

| Selecta | Launcha | Bindings |
|:--:|:--:|:--:|
| ![Selecta menu](docs/images/selecta.webp) | ![Launcha app search](docs/images/launcha.webp) | ![Shortcut bindings](docs/images/bindings.webp) |

## Install

Ting requires **macOS 14 or later** and runs natively on Apple Silicon and Intel.

### Homebrew

```sh
brew install --cask bobuk-io/tap/ting
open /Applications/Ting.app
```

If Homebrew asks you to trust the cask, run `brew trust --cask bobuk-io/tap/ting`, then repeat the install command.

### Download

Download the universal ZIP from [GitHub Releases](https://github.com/bobuk-io/ting/releases/latest), unzip it, move `Ting.app` to `/Applications`, and open it. Official releases are signed with Developer ID, notarized by Apple and include a stapled ticket.

On first launch, choose a non-modifier key to use as your leader. Ting has no default leader.

## Use

- **Selecta:** press the leader, then a key or short sequence. Groups can be nested. Open apps, URLs, app links such as `raycast://`, or [micro-apps](docs/micro-apps/FORMAT.md).
- **Launcha:** press the leader twice at the top level, set its optional global hotkey in Settings, or choose **Open launcha** from Ting's menu. Type part of an app or micro-app name and press `Return`.
- **Clipbawd:** search for **Clipbawd** in launcha and press Return, set its optional hotkey in Settings › Clipbawd, bind it in selecta, or choose **Open Clipbawd** from Ting's menu. It lists what you copied in this session, newest first, with a preview and details: the source app, the type, the size of an image, the length of a text, the size of files, and when it was copied. Copying the same thing again moves it up instead of adding it twice. `Return` pastes, `⌘Return` copies, `⇧⌘⌫` removes. Turn **Use Clipbawd** off in Settings if you do not want it: Ting then never reads the clipboard.
- **App shortcuts:** in launcha, select an app and press `⌘⇧K`, or use its context menu to record a global shortcut. A new shortcut replaces that app's old one. Ting asks before taking a shortcut from another app. The leader, launcha and clipbawd hotkeys are reserved.
- **Settings:** press `⌘,` in selecta, launcha or clipbawd, or choose **Settings…** from Ting's menu. Other `⌘` shortcuts such as `⌘Q` are ignored while a launcher is open.
- **Fast sequences:** type a complete sequence quickly and selecta opens the destination without showing intermediate menus. Change the delay in Settings.
- **Keyboard layouts:** bindings use physical keys and keep working across layouts. Launcha also understands text typed with the wrong layout.
- **Calculator and converter:** launcha can calculate expressions and convert units, number bases, dates and Unix time.

![Launcha searches apps as you type](docs/images/launcha.webp)

## Micro-apps

Micro-apps are small, user-approved tools defined as YAML files. A tool can ask for input, read the clipboard or current context, run shell or Python code, make HTTP or AI requests, and show or paste its result. The folder starts empty; Ting installs no scripts and has no built-in editor.

An approved micro-app can read a snapshot of Clipbawd history with `${clipboard[-1]}` (newest), `${clipboard[-2]}` (previous), and so on. Text, links and colors return text; files return newline-separated paths. Images, missing entries, disabled history and headless runs fail explicitly. The snapshot stays fixed for the run. Use `env:` for shell commands, never interpolate history into shell code:

```yaml
format: ting.microapp/2
description: Show the newest clipboard history item
input: none
steps:
  - text: ${clipboard[-1]}
output:
  to: [panel]
```

See the [micro-app format and examples](docs/micro-apps/FORMAT.md). Review a file before approving it: its commands run with your user permissions and may access the network.

## Updates

A downloaded copy checks for updates with [Sparkle](https://sparkle-project.org); choose **Check for Updates…** in Ting's menu to check now. A Homebrew-installed copy updates only when you choose **Update Ting via Homebrew…** from the menu or Settings. Both update methods keep your settings and shortcuts.

To uninstall a Homebrew copy, turn off launch at login, quit Ting, then run:

```sh
brew uninstall --cask bobuk-io/tap/ting
```

This keeps your data. Add `--zap` only if you also want to delete settings, micro-apps, approvals and history.

## Privacy and permissions

Ting has no accounts, analytics or backend. It does not ask for Input Monitoring permission and does not read keystrokes outside its own panels; Accessibility is needed to paste into another app, read selection/window context, or inspect Firefox private-window titles. Launcha searches your installed apps and, when allowed, selected folders. It keeps usage counts locally. Micro-apps run only after approval.

Clipbawd keeps the clipboard history in memory only and never writes it to disk. It skips copies made while Secure Keyboard Entry is on, copies that password managers mark as secret, copies from private browser windows it can recognise (Firefox and its forks; Chrome, Brave, Edge and Vivaldi when you allow it), copies from apps you exclude, or text that starts with a prefix you list. It loads nothing from copied links unless you turn on **Fetch link titles, icons and images**.

Read the [security policy](SECURITY.md) for the security model and private vulnerability reporting.

## Documentation

- [Configuration and key bindings](docs/CONFIGURING.md)
- [Micro-app format and examples](docs/micro-apps/FORMAT.md)
- [Release notes](docs/releases/)
- [Ting on bobuk.io](https://bobuk.io/apps/ting/)

## Development

Build and test on macOS with Swift 6.2 or later:

```sh
swift build
swift test
./Scripts/run.sh
```

Use `TING_CONFIG=/tmp/ting-test.json` to keep your personal configuration untouched. See [contributing and release scripts](Scripts/) and the [release notes for 0.7.5](docs/releases/v0.7.5.md).

## License

Original Ting code is licensed under [0BSD](LICENSE). Adapted build and release scripts retain their MIT attribution; Sparkle is distributed under its own license. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
