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

The menu appears on the display that contains the pointer, above full-screen
apps and on every Space.

## Settings

Choose **Settings…** in the menu-bar menu, or open Ting again from Finder or
Spotlight.

- **General:** light or dark theme (dark by default), the leader key, the menu
  delay, what an unknown key does, launch at login, the menu-bar icon, the
  "ting" sound and update checks.
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
  `light`), `launchAtLogin`, `showMenuBarIcon`, `playSound`.

## Privacy and permissions

Ting registers its leader with the standard macOS hotkey API. It does not ask for
Accessibility or Input Monitoring permission and does not read keystrokes outside
its own menu.

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
