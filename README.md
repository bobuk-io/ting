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

On first launch, choose a non-modifier key to use as your leader. If you switch keyboards, record another key in **Settings › Keys & Launch › Second leader**. Either key opens the same selecta bindings. When double tap is enabled, either key also opens launcha with two taps.

## Use

- **Selecta:** press the leader, then a key or short sequence. Groups can be nested. Open apps, URLs, app links such as `raycast://`, run window commands, or start [micro-apps](docs/micro-apps/FORMAT.md).
- **Launcha:** press the leader twice at the top level, set its optional global hotkey in Settings, or choose **Open launcha** from Ting's menu. Type part of an app or micro-app name and press `Return`.
- **Clipbawd:** search for **Clipbawd** in launcha and press Return, set its optional hotkey in Settings › Clipbawd, bind it in selecta, or choose **Open Clipbawd** from Ting's menu. It lists your clipboard history, newest first, with a preview and details: the source app, the type, the size of an image, the length of a text, the size of files, and when it was copied. Copying the same thing again moves it up instead of adding it twice. `Return` pastes, `⌘Return` copies, `⇧⌘⌫` removes. Turn **Use Clipbawd** off in Settings if you do not want it: Ting then never reads the clipboard.
- **Chatta:** open a chat window with your local ACP agent (`Antigravity`, `Codex`, `Claude`, `Pi`, `Kimi`, `Gemini`, `OpenCode`) from Ting's menu, **launcha** (`chatta`), a **selecta** binding, or an optional hotkey in **Settings › Chatta**. Use **Chat** for quick text-only conversations or **Configure Ting** to let the agent edit bindings and create/check micro-apps in your Ting folder inside a Seatbelt sandbox. When a base CLI (`codex`, `claude`, `pi`) is installed without its `-acp` adapter, Chatta offers one-click installation.
- **Window management:** move or resize the focused window into halves, quarters or thirds; maximize or center it; restore its previous frame; or move it to another display. Add a leader binding from **Settings › Bindings › + › Window**, or record direct hotkeys and choose the gap in **Settings › Windows**. Window commands require Accessibility permission.
- **Settings:** press `⌘,` in selecta, launcha or clipbawd, or choose **Settings…** from Ting's menu. One BobukKit window (`ChromeWindow`) with a permanent sidebar for General, Keys & Launch, Bindings, Windows, Clipbawd, Chatta, Micro-apps and Advanced. The sidebar cannot be hidden or collapsed; up/down arrows navigate its focused rows. The window has a thin amber accent line and a control strip; the strip's close button and `⌘W` close Settings, including while search is focused. There is no titlebar with traffic-light buttons and no close button inside the content. Drag the strip to move the window; resize at its edges. Search finds individual settings, including sound, retention and permissions. Ting's menu keeps quick actions on top; config/reload/agent commands are under **Tools**, and updates/About under **Ting**.
- **App shortcuts:** in launcha, select an app and press `⌘⇧K`, or use its context menu to record a global shortcut. A new shortcut replaces that app's old one. Ting asks before taking a shortcut from another app. Launcher and window-management hotkeys are reserved.
- **Fast sequences:** selecta shows the menu immediately by default. To keep it hidden while typing a familiar sequence, increase **Settings › Keys & Launch › Show menu after**.
- **Keyboard layouts:** bindings use physical keys and keep working across layouts. Launcha also understands text typed with the wrong layout.
- **Calculator and converter:** launcha can calculate expressions and convert units, number bases, dates and Unix time.
- **Fuzzy search and ranking:** launcha finds names by scattered letters and forgives a typo (`1pwd` and `1pvd` find 1Password) and highlights the matched letters. Names that contain the query as typed come first; within a group, apps you launch more often rank higher. Opt in to **Settings › Keys & Launch › Rank by apps you use** to also count apps you switch to outside launcha, and choose whether running apps go higher or lower.
- **Shared BobukKit UI:** selecta, launcha, Clipbawd and micro-app flows are BobukKit panels (`BobukPanel`): Esc, `⌘W` and focus loss close them, `⌘C`/`⌘V`/`⌘X`/`⌘A`/`⌘Z` reach the text field on any keyboard layout, and other `⌘` shortcuts (`⌘Q`) are swallowed. They use the kit's consistent rows, rounded panel frame and wrapping shortcut hints. Settings, Welcome and the Accessibility window are kit `ChromeWindow`s; Settings reuses the navigation rows and native search input while keeping native form controls, and all menu and reopen actions use that one window. Global hotkeys, the toast, launch at login and Homebrew updates also come from the kit. Each app keeps its own colors and commands. The self-contained copy in `Vendor/BobukKit` comes from `~/GitHub/bobuk.io/BobukKit`; edit the canonical kit and run its `Scripts/sync.sh` / `Scripts/sync.sh --check` for all consumers.
- **lowkey sites:** when lowkey is installed, Settings › Bindings › + › lowkey lists its saved sites with **Open** and **Toggle** commands for selecta. Launcha finds the same sites by title, alias or host and opens them in their lowkey profiles. Existing site bindings keep their URLs in settings. Ting runs the installed `lowkey.app/Contents/Helpers/lowkeyctl` directly for single-site open, toggle and hide; these commands require a lowkey build with the helper. Single-site `rewind` also uses the helper and reloads the configured start page. Other lowkey URLs still go to lowkey. To inspect controls, wait, click, fill, select or attach a file, use a native [lowkey micro-app step](docs/micro-apps/FORMAT.md#lowkey-steps). Starting with Ting 0.7.16 and lowkey 0.1.2, `action: save-pdf` with a templated `file:` path exports a complete page to PDF without overwriting an existing file. Agents configuring hotkeys should start with [lowkey sites](docs/CONFIGURING.md#lowkey-sites). Ting reads only `~/.config/lowkey/config.json`, not cookies or website data. Changes appear on the next open and refresh while the list is open.

![Launcha searches apps as you type](docs/images/launcha.webp)

## Micro-apps

Micro-apps are small, user-approved tools defined as YAML files. A tool can ask for input, read the clipboard or current context, run shell or Python code, make HTTP, AI or local ACP (`chatta:`) requests, and show or paste its result. The folder starts empty; Ting installs no scripts and has no built-in editor. **Settings › Micro-apps** lets you adjust the maximum timeout, result panel width, and result text size.

An approved micro-app can read a snapshot of Clipbawd history with `${clipboard[-1]}` (newest), `${clipboard[-2]}` (previous), and so on. Text, links and colors return text; files return newline-separated paths. Images, videos, missing entries, disabled history and headless runs fail explicitly. The snapshot stays fixed for the run. Use `env:` for shell commands, never interpolate history into shell code:

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

A downloaded copy checks for updates with [Sparkle](https://sparkle-project.org); choose **Ting › Check for Updates…** in Ting's menu to check now. A Homebrew-installed copy updates only when you choose **Ting › Update Ting via Homebrew…** from the menu or Settings. Both update methods keep your settings and shortcuts.

To uninstall a Homebrew copy, turn off launch at login, quit Ting, then run:

```sh
brew uninstall --cask bobuk-io/tap/ting
```

This keeps your data. Add `--zap` only if you also want to delete settings, micro-apps, approvals and history.

## Privacy and permissions

Ting has no accounts, analytics or backend. It does not ask for Input Monitoring permission and does not read keystrokes outside its own panels; Accessibility is needed to move or resize windows, paste into another app, read selection/window context, or inspect Firefox private-window titles. Launcha searches your installed apps and, when allowed, selected folders. It keeps usage counts locally. Micro-apps run only after approval.

Clipbawd keeps history in memory by default. Enable **Settings › Clipbawd › Keep history between launches** to save it locally in `~/Library/Application Support/Ting/Clipbawd/`. The archive is restricted to your user and excluded from backups, but has no additional encryption. Turning persistence off deletes the stored archive; the current session remains in memory. **Clear History** or turning **Use Clipbawd** off deletes both. File deletion is not a secure erase of filesystem snapshots or existing backups.

**Retention limits** defaults to 100 entries, 50 MiB and 30 days; all three are configurable and 0 days means no age limit. Limits apply to session history too. Oldest copies are removed when count/size limits are exceeded; age cleanup runs hourly and on restore/config changes. Reusing an entry does not reset its age; copying it again does. The disk bound also includes archive metadata. Settings show both payload usage and the actual archive size. Existing explicitly configured limits are kept.

Clipbawd supports PNG, JPEG and TIFF images, basic Markdown syntax coloring without loading embedded images, and one local MP4/MOV/M4V video per copy (up to 30 seconds and 32 MiB including other retained representations). Video previews show a thumbnail and duration, with no playback. Unsupported or longer movies are skipped. Movie bytes are owned by the history, so the source can be deleted; other files remain path references, not file backups. Copying a video creates one private temporary file for apps that accept file URLs; the next video replaces it, and clearing/disabling history removes it.

Clipbawd skips copies made while Secure Keyboard Entry is on, copies that password managers mark as secret, copies from private browser windows it can recognise (Firefox and its forks; Chrome, Brave, Edge and Vivaldi when you allow it), copies from apps you exclude, or text that starts with a prefix you list. It loads nothing from copied links unless you turn on **Fetch link titles, icons and images**.

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
