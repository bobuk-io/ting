# Ting

A leader-key launcher for macOS. Press your leader key, then one key or a short
sequence to open an app or a link — without a search field, the Dock or the mouse.

```text
Home  space      →  WezTerm
Home  t  r       →  raycast://extensions/raycast/ai/to-russian
Home  w  d  s    →  https://developer.apple.com/documentation/swiftui
```

*Ting* is Jamaican patois and London slang for "thing". The menu borrows a little
from grime and sound-system culture: amber keycaps on graphite, `esc pull up`,
`⌫ rewind`.

Requires **macOS 14 or later**. Official releases are universal builds for
**Apple Silicon and Intel**.

## Install

1. Download the universal ZIP from [Releases](https://github.com/bobuk-io/ting/releases/latest).
2. Unzip it and move `Ting.app` to `/Applications`.
3. Open Ting. It lives in the menu bar and has no Dock icon.
4. Press the key you want as your leader. There is no default leader.

Official releases are signed with Developer ID, notarized by Apple and include a
stapled notarization ticket. Each release includes a SHA-256 checksum. Ting
updates itself with [Sparkle](https://sparkle-project.org) from this repository's
releases; you can turn automatic checks off in Settings.

## Use

- **Leader:** any key that is not a modifier, alone or with modifiers — for
  example `Home`, `F13` or `⌥⇧⌘F`. A modifier on its own (such as Right `⌥`)
  cannot be a leader.
- **Sequences:** letters, digits, `Space`, `Return` and F-keys. Groups can be
  nested as deep as you like. `Esc` closes the menu, `Delete` goes back one level.
- **Actions:** open an app (an app that is already running comes to the front)
  or open a URL with its default handler — web links and app URL schemes such as
  `raycast://` or `hascs://`. Shell commands are not supported.
- **Any keyboard layout:** bindings are stored by the Latin letter of the key, so
  they keep working with Russian, Ukrainian or any other layout. The menu shows
  the current layout's letter as a small hint next to the Latin one.
- **Fast typing:** if you type the whole sequence quickly, the menu never appears.
  The delay is 0.25 s by default and can be changed in Settings.

The menu shows the leader as a tuning-fork symbol; its tooltip names your configured key.

The menu appears on the display that contains the pointer, above full-screen
apps and on every Space.

## launcha (unreleased)

> launcha is in development on `main` and is not part of a published release yet.

The leader menu is called **selecta**. **launcha** is its search companion: type
part of an app name and press `Return`.

- **Open it:** press the leader twice at the top level of selecta. The first
  press opens selecta at once, so sequences are never delayed; any key in
  between cancels the double tap. The interval is 0.3 s by default (0.1–1 s).
  You can also set a separate global hotkey (unset by default) or choose
  **Open launcha** in the menu-bar menu.
- **Search:** an empty field lists your apps, most-used first. Matching ignores
  case and accents, understands word starts and initials (`vsc` → Visual Studio
  Code) and text typed with the wrong layout (`ыфафкш` → Safari). Paste, editing
  and input methods work as in any Mac text field.
- **Keys:** `↑` `↓` choose, `Return` opens, `⌘Return` shows the item in Finder,
  `Esc` closes. launcha also closes when you click elsewhere or switch Spaces.
- **Apps:** from `/Applications`, `/System/Applications` and `~/Applications`.
  launcha opens the exact app bundle it found; a running app comes to the front.
  Ting scans these folders once at startup, again each time launcha opens and
  every 15 seconds while it stays open, so new apps appear without a restart.
- **Files:** only when no app matches, launcha asks Spotlight for files in your
  home folder (not `~/Library`, hidden folders or app bundles) and opens a file
  with its usual app.
- **Desktop, Documents and Downloads** are not searched until you allow it, in
  launcha or in Settings. macOS may then ask you to allow Ting to access each
  folder. Desktop apps are listed after that. Until then launcha says that these
  folders were skipped.
- **Ranking:** Ting counts successful opens through selecta and launcha over the
  last 7 days. Failed opens and Finder reveals do not count. Ting does not watch
  apps you open in other ways.

The usage history and the folder choice are stored apart from the config file,
in `~/Library/Application Support/Ting/` (`launcha-history.json`,
`launcha-consent.json`). With `TING_CONFIG` set, both sit next to that file
instead, with the config file name in front: `TING_CONFIG=/tmp/ting-test.json`
uses `/tmp/ting-test.json.launcha-history.json` and
`/tmp/ting-test.json.launcha-consent.json`.

## Settings

Choose **Settings…** in the menu-bar menu, or open Ting again from Finder or
Spotlight.

- **General:** light or dark theme (dark by default), the leader key, the menu
  delay, what an unknown key does, launch at login, the menu-bar icon, the
  "ting" sound and update checks. “Show panel title” controls the `Ting · selecta`
  title row (on by default); hiding it keeps the leader symbol and sequence visible.
  The launcha section (unreleased) sets its hotkey, the leader double tap and its
  interval, and access to Desktop, Documents and Downloads.
- **Bindings:** one table of key sequences. Click the record button, type the
  keys and press **Done** (`Space` and `Return` are recorded as keys). Missing
  groups are created and empty groups are removed automatically. If a shorter
  sequence already opens something, Ting offers to turn it into a group.
- **Advanced:** the config file location, reveal, open, reload, import and export.

## Configuration file

Everything lives in one JSON file, `~/.config/ting/config.json`. Ting creates a
sample on first launch, reloads the file when it changes and keeps the last good
settings if the file has an error; the error appears in the menu-bar menu. Keep
the file in your dotfiles if you like.

```json
{
  "version": 1,
  "leader": "home",
  "showDelay": 0.25,
  "items": [
    { "key": "space", "label": "WezTerm", "app": "com.github.wez.wezterm" },
    { "key": "w", "label": "Web", "items": [
      { "key": "g", "label": "GitHub", "url": "https://github.com" }
    ]}
  ]
}
```

- Each item has a `key`, an optional `label` and exactly one of `items` (a
  group), `app` (a bundle identifier) or `url`.
- `key` is a lower-case Latin letter or digit, `space`, `return` or `f1`…`f20`.
- `leader` is a key name such as `home`, `f13` or `space`, optionally with
  modifiers: `option+shift+cmd+f`, `ctrl+space`.
- Other settings: `unknownKey` (`shake` or `close`), `appearance` (`dark` or
  `light`), `launchAtLogin`, `showMenuBarIcon`, `showPanelHeader`, `playSound`.
- `launcha` (unreleased): `{"hotkey": null, "doubleTap": true,
  "doubleTapWindow": 0.3}`. `hotkey` uses the leader format and must differ
  from the leader.

## Privacy and permissions

Ting registers its leader (and the optional launcha hotkey) with the standard
macOS hotkey API. It does not ask for Accessibility or Input Monitoring
permission and does not read keystrokes outside its own panels. launcha reads
the app folders at startup, when it opens and every 15 seconds while it is
open. It asks Spotlight for file names only for what you type, and only when no
app matches. It keeps its launch counts on your Mac.

Ting has no accounts, analytics or servers. It opens the apps and URLs you
configure. Sparkle checks this repository's public release feed for updates and
downloads updates from GitHub. See [SECURITY.md](SECURITY.md) for the security
model and private vulnerability reporting.

## Develop

Use Xcode or Command Line Tools with **Swift 6.2 or later** on macOS:

```sh
swift build
swift test
./Scripts/run.sh
```

`run.sh` builds a development copy in `build/` and starts it. Development builds
are ad-hoc signed, not notarized, and never check for updates. Set
`TING_CONFIG=/tmp/ting-test.json` to keep your real configuration untouched.

The SwiftUI interface and AppKit panel, hotkey and menu-bar wiring live in
`Sources/Ting`. The config format, key names, the binding tree and the leader
state machine live in `Sources/TingCore` and are covered by the tests in
`Tests/TingCoreTests`.

The app icon master is `Assets/AppIcon.png` (1024×1024, transparent). Packaging
runs `Scripts/build_icon.sh`, which generates every standard and Retina size with
`sips` and `iconutil`.

## Release

Releases are built on a trusted maintainer workstation with a Developer ID
Application identity, a saved `notarytool` Keychain profile and the Sparkle
EdDSA key in the login Keychain (account `io.bobuk.ting`). Unpack the verified
Sparkle 2.10.1 release tools to `.build/sparkle-tools` or set `SPARKLE_BIN` to
their `bin` directory. Then:

1. Increase `MARKETING_VERSION` and `BUILD_NUMBER` in `version.env` and add
   `docs/releases/v<version>.md`.
2. Build, notarize, sign the appcast and install:

   ```sh
   APP_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
   NOTARY_PROFILE=ting \
   ./Scripts/release.sh
   ```

   The script runs the tests, builds a universal app, removes debug-map paths,
   checks the bundle and local-path leakage, signs and notarizes the app, staples
   the ticket, writes the ZIP, `SHA256SUMS.txt` and the signed `appcast.xml` to
   `dist/`, then **installs the release at `/Applications/Ting.app` and restarts
   it**. The previous installation is kept until the new one starts.
3. Commit, push `main`, then publish:

   ```sh
   ./Scripts/publish.sh
   ```

   The release is created as a draft, all assets are uploaded, and then it is
   published, so Sparkle never sees an incomplete release.

Back up the Sparkle private key securely offline: without it, installed copies
cannot verify future updates. Never commit or publish it.

## License

Original Ting code is licensed under [0BSD](LICENSE). Adapted build and release
scripts keep their upstream MIT license; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Sparkle is distributed under
its own license, included in the notices.
