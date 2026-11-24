# Configuring Ting with a coding agent

This document tells a coding agent such as Claude Code, Codex or pi how to
change Ting for a person: key bindings, settings and micro-apps. It ships inside
the app as `Ting.app/Contents/Resources/CONFIGURING.md`; the micro-app format is
in `FORMAT.md` next to it.

The person asks in plain words, for example:

> Write a new micro-app: Leader `t` `a` should translate the clipboard into German.

> Bind Leader `w` `j` to https://jira.example.com.

> Open Ghostty with Leader `space`.

## Files

| What | Where |
|---|---|
| Settings and bindings | `~/.config/ting/config.json` |
| Micro-apps | `~/.config/ting/micro/*.yaml` |
| Libraries of micro-apps | `~/.config/ting/micro/libs/*.yaml` |
| Problems of micro-app files | `~/.config/ting/micro-errors.log` |
| Console tool | `/Applications/Ting.app/Contents/MacOS/ting-micro` |
| Micro-app format | `/Applications/Ting.app/Contents/Resources/FORMAT.md` |

With `TING_CONFIG=/path/x.json` set, the config is that file, the micro-apps are
in `/path/x.json.micro/` and the log is `/path/x.json.micro-errors.log`.

Ting reloads `config.json` and the micro-apps folder by itself when they change;
nothing needs a restart. **Never** write the approvals and remembered values in
`~/Library/Application Support/Ting/`, and never change `Ting.app`.

## `config.json`

```json
{
  "version": 1,
  "leader": "home",
  "alternateLeader": "f13",
  "items": [
    { "key": "space", "label": "WezTerm", "app": "com.github.wez.wezterm" },
    { "key": "t", "label": "Translate", "items": [
      { "key": "u", "label": "Translate to Ukrainian", "micro": "translate-ukrainian" }
    ]},
    { "key": "w", "label": "Windows", "items": [
      { "key": "h", "label": "Left Half", "window": "left-half" },
      { "key": "l", "label": "Right Half", "window": "right-half" }
    ]},
    { "key": "g", "label": "GitHub", "url": "https://github.com" }
  ]
}
```

- `items` is a tree. A key sequence such as Leader `t` `a` is the item with
  `"key": "a"` inside the group with `"key": "t"`.
- Each item has `key`, an optional `label` (shown in the menu) and exactly one
  action: `items` (a group), `app` (a bundle identifier), `url` (any URL,
  including schemes such as `raycast://`), `micro` (a micro-app id), `open`
  (a Ting window: `"launcha"`, `"clipbawd"` or `"chatta"`) or `window`
  (a focused-window command such as `"left-half"`).
- `key`: a lower-case Latin letter or digit, `space`, `return` or `f1`…`f20`. Keys
  are Latin even when the person types with another layout.
- In one group a key is used once.
- `alternateLeader` is an optional second leader, recorded in Settings › Keys & Launch. Either key opens the same bindings. Two successive taps of either key open launcha when double tap is enabled. Omit the field or set it to `null` to clear it.
- Settings: `leader` (a key name with optional modifiers, such as `home`,
  `f13`, `option+shift+cmd+f`; `pause` is the Pause key of a PC keyboard, the same key as `f15`
  and saved as `f15`; never a modifier alone), `showDelay` (seconds,
  0–2, default 0 for immediate display), `unknownKey` (`shake` or `close`), `appearance` (`dark` or `light`),
  `launchAtLogin`, `showMenuBarIcon`, `showPanelHeader`, `playSound` (booleans),
  `sound` (a system sound name from `/System/Library/Sounds` without extension,
  default `Purr`; an unknown name plays `Purr`), `soundVolume` (0–1, default 0.5),
  `launcha` (`{"hotkey": null, "doubleTap": true, "doubleTapWindow": 0.3, "calculator": true,
  "converter": true, "appSwitching": false, "runningApps": "any"}`; `calculator` shows the value of a query such as `2*(3+4)` first in
  launcha, `converter` that of `5 yd to m`, `255 to hex` or `now + 2 days`; `appSwitching` also ranks
  apps by how often you bring them to the front outside launcha, counted at most once per app every
  30 minutes; `runningApps` (`higher`, `lower` or `any`, used only with `appSwitching`) lists running
  apps first or last among equally good matches),
  `clipbawd` (`{"hotkey": null, "enabled": true, "fetchLinks": false, "maxItems": 100,
  "persistent": false, "maxMegabytes": 50, "maxDays": 30,
  "excludedApps": [], "ignoredPrefixes": []}`; `enabled: false` turns clipbawd off: Ting never reads the clipboard,
  the hotkey is free and the window does not open;
  `fetchLinks` loads the title, icon or image of a copied link, `maxItems` is
  20–1000, `persistent` saves history between launches (off by default; turning it off deletes the archive),
  `maxMegabytes` is 1–4096 MiB (including all representations and disk archive metadata),
  `maxDays` is 0–3650 (0 means no age limit). The oldest external copies are dropped until all limits hold;
  age cleanup is hourly and on restore/config changes. Limits apply in memory too; reuse does not reset age.
  `excludedApps` lists bundle identifiers whose copies are never kept,
  `ignoredPrefixes` lists case-sensitive starts of text that is never kept),
  `microApps` (`{"maxTimeout": 300, "resultWidth": 580, "resultTextSize": 13}`; `maxTimeout` is
  60–86400 seconds and caps the `timeout` a micro-app file may ask for, while each file still defaults
  to 60s and may set any smaller or larger value up to that limit; `resultWidth` is 480–1200 points
  for the result panel card; `resultTextSize` is 11–24 points for result panel body text),
  `chatta` (`{"hotkey": null, "agent": null, "model": null, "effort": null, "idleTimeoutMinutes": 15, "allowTools": false}`;
  `hotkey` opens the Chatta agent chat window; `agent` picks a built-in ACP preset id
  (`antigravity`, `codex`, `claude`, `pi`, `kimi`, `gemini`, `opencode`, or `null` to auto-detect);
  `model` and `effort` (`low`, `medium`, `high`, `xhigh`, `max`) set optional defaults shared by the
  Chatta window and `chatta:` micro-app steps; `idleTimeoutMinutes` (0–240, 0 disables) stops an idle
  agent subprocess after inactivity while keeping the transcript visible; `allowTools` is `false` by
  default and lets agents use built-in tools such as `web_search` in Chat mode inside the sandbox,
  prompting once on the first tool call when off to allow always, for this session, or decline),
  `windowManagement` (`{"gap": 0, "shortcuts": []}`; `gap` is 0–64 points at display edges and
  between adjacent tiles; each shortcut has a `command` and `hotkey`). The Clipbawd, Chatta and
  window-command hotkeys cannot conflict with another Ting hotkey. Clipbawd (while enabled) and
  Chatta are also searchable by name in launcha.
- Approved micro-app templates can read `${clipboard[-1]}` (newest history entry), `${clipboard[-2]}`, etc. The snapshot is fixed at run start. Pass history to shell through `env:`; never interpolate it into code. Disabled/unavailable history, images, videos and missing entries fail explicitly. Files yield newline-separated paths. The headless runner has no session history.

### Settings and clipboard storage

Settings has a sidebar and search across all categories. Leader and launcha controls are in **Keys & Launch**,
window gaps and direct window hotkeys in **Windows**, permissions and micro-app diagnostics in **Micro-apps**,
and file/import/export actions in **Advanced**.
The menu's **Tools** submenu holds config, reload and Copy Agent Prompt; **Ting** holds About and updates.

Persistent clipboard history is a local binary archive in `~/Library/Application Support/Ting/Clipbawd/history.plist`,
without additional encryption and excluded from backups. With `TING_CONFIG=/tmp/demo.json`, its isolated directory
is `/tmp/demo.json.clipbawd/`; development/tests must always use an override. Do not edit archives manually.
Turning Clipbawd off or Clear History deletes memory and disk data. Turning persistence off deletes disk data only.
New exclusions also remove matching retained entries. Generic files remain references; images and video bytes are retained.
Markdown source gets basic syntax coloring, never embedded-image loading. One MP4/MOV/M4V clip up to 30 seconds
and 32 MiB per copy is supported, with thumbnail/duration but no playback. Longer, unsupported or unreadable videos are skipped.
The size limit may reject a new capture; shrinking limits evicts oldest copies, even a single oversized remaining entry.

### lowkey sites

When lowkey is installed, Settings › Bindings › + › lowkey lists the saved sites
from `~/.config/lowkey/config.json`. Choose **Open** to show the site's existing
window (or create it), or **Toggle** to hide/show it without losing its profile.
These are regular URL bindings; there is no new config action:

```json
{ "key": "w", "label": "Work", "url": "lowkey://work/open" }
```

Use `lowkey://work/toggle` for toggle, replacing `work` with the actual saved-site
alias. Never invent aliases or change lowkey's settings just to create a Ting
binding. Launcha also lists saved sites, independently of bindings, by title,
alias and host; Return opens the site in its lowkey profile. Removed sites are
removed from search on refresh. Old bindings retain their alias and can be edited
or deleted normally. Ting never reads lowkey's cookies or website-data stores.

**Binding or micro-app?** For a single shortcut that shows or hides a site, keep
its URL binding. For a sequence such as “open the site, wait for a button, then
click it”, bind a micro-app and use native `lowkey` steps. Do not put shell code,
page scripts or a file path in a lowkey URL. The helper's argument order is
`lowkeyctl ALIAS COMMAND`, for example `lowkeyctl work inspect --json`.

Read the **lowkey steps** section of `FORMAT.md` in this app's `Contents/Resources`
(in the repository: [FORMAT.md](micro-apps/FORMAT.md#lowkey-steps)). Start with
`status` or `inspect`, not a click. Use a saved alias supplied by the person;
confirm the intended site and file before trying an upload. Validate the YAML
with `ting-micro check`; it does not run the steps.

### Direct application hotkeys

`appHotkeys` is an optional list, empty by default. In launcha, select an app
and press Command-Shift-K, or open its context menu and choose **Set Global
Shortcut…**. Press the shortcut, then Return or Save. Record Again captures
another key, Remove Global Shortcut clears the assignment, and Esc cancels.
Files, calculations, lowkey sites and micro-apps have no direct application shortcut editor.

```json
"appHotkeys": [
  {
    "id": "app:com.apple.safari",
    "name": "Safari",
    "path": "/Applications/Safari.app",
    "hotkey": "cmd+f12"
  }
]
```

This fragment belongs at the top level of `config.json`. `id` is the stable
launcha/history identity, normally `app:` plus the lower-case bundle identifier;
keep the id produced by launcha for apps without a bundle identifier. `path`
is the absolute path of the indexed `.app` bundle, not an executable. Ting opens
that exact copy or brings it forward. `name` is its display name. `hotkey` uses
the same syntax as the leader: a non-modifier key, optionally with modifiers.

Each app has one shortcut and each shortcut belongs to one app. Saving in
launcha replaces both the app's old shortcut and any other app's assignment to
the new shortcut; the editor names the other app before Save. Both leaders, launcher hotkeys and
window-command hotkeys are reserved, even while recording suspends them. An OS registration
conflict or failed save keeps the old configuration.

In a hand-written file, invalid or duplicate entries produce validation
issues; only the first valid assignment for an app and key is registered.
An app shortcut that conflicts with either leader, a launcher hotkey or a window-command hotkey is
disabled, never the protected shortcut. Changing a protected key later can therefore disable
an app assignment without deleting it. Pausing Ting or recording a shortcut
suspends application hotkeys too. Holding an app shortcut launches only once
until release. Successful launches count toward launcha's ranking.

### Window management

A binding can use one of these `window` values:

```text
left-half, right-half, top-half, bottom-half
top-left-quarter, top-right-quarter, bottom-left-quarter, bottom-right-quarter
first-third, center-third, last-third
maximize, center, restore, previous-display, next-display
```

The same commands can have direct global shortcuts:

```json
"windowManagement": {
  "gap": 8,
  "shortcuts": [
    { "command": "left-half", "hotkey": "option+cmd+left" },
    { "command": "right-half", "hotkey": "option+cmd+right" }
  ]
}
```

Window commands act on the focused window and require Accessibility permission. `center` keeps the
current size. `restore` returns to the frame saved before Ting first moved that window in this app
session. Previous/next display preserves size when it fits and keeps the relative position. Spaces
are not controlled. A window hotkey cannot reuse a leader, launcher, app or another window hotkey.

Find an app's bundle identifier with
`mdls -name kMDItemCFBundleIdentifier -r /Applications/Ghostty.app`.

## Changing the config

1. Read `config.json` and find where the change goes. Keep every other item,
   setting and the order of the file.
2. Ask the person first when the change would replace or move something:
   - the sequence is already bound;
   - a shorter part of it is an app, URL or micro-app, not a group. For example,
     Leader `t` opens Terminal, and you need Leader `t` `a`.
3. Copy the file to a backup in a temporary folder, then edit it.
4. Check the result:

   ```sh
   /Applications/Ting.app/Contents/MacOS/ting-micro check-config
   ```

   It prints `<file>: ok`, or one line per problem: JSON and format errors,
   duplicate keys, empty targets, bad URLs and `micro` ids that do not load.
   Fix every problem. With a broken file Ting keeps its last good settings and
   shows the error in its menu.
5. Tell the person what changed and the backup path.

## Adding a micro-app with a key

1. Read `FORMAT.md` and follow its workflow: look for a library to reuse, write
   and check the file in a temporary folder, then move it into
   `~/.config/ting/micro/`.
2. Bind it: add `{"key": "…", "label": "…", "micro": "<id>"}` at the sequence the
   person asked for, creating the groups on the way.
3. Run `ting-micro check-config`. It also checks that the micro-app id loads.
4. Tell the person that the first start shows an approval panel and that `⌘↩`
   approves the file. Name any API key or keychain item the micro-app needs.

### Worked example

> Write a new micro-app: Leader `t` `a` should translate the clipboard into German.

1. `~/.config/ting/micro/libs/translate.yaml` exists and its step has
   `id: translate`. Inherit it instead of copying the prompt. Write
   `translate-german.yaml` in a temporary folder:

   ```yaml
   format: ting.microapp/2
   inherit: translate
   id: translate-german
   name: Translate to German
   description: Translate the clipboard text into German with OpenAI.

   steps:
     - id: translate
       params:
         language: German
   ```

   Without that library, write the micro-app with its own `ai` step, or first
   move the shared steps into a new library if other translate micro-apps
   exist.
2. Check the file against the person's libraries:

   ```sh
   MICRO=/Applications/Ting.app/Contents/MacOS/ting-micro
   "$MICRO" check --libs ~/.config/ting/micro/libs "$dir/translate-german.yaml"
   ```

   Then move it into `~/.config/ting/micro/` and read `micro-errors.log`.
3. In `config.json`, the group `t` exists (`"label": "Translate"`). Key `a` is
   free there, so add:

   ```json
   { "key": "a", "label": "Translate to German", "micro": "translate-german" }
   ```

   Without a group `t`, add `{"key": "t", "label": "Translate", "items": [ … ]}`.
   If `t` is bound to something else, ask first.
4. Run `"$MICRO" check-config` until it prints `ok`.
5. Report: "Leader t a runs Translate to German. Approve it with ⌘↩ at the first
   start. It uses OPENAI_API_KEY from your shell."

Do not run the micro-app yourself to test it when it calls a paid API or changes
files; ask first. `ting-micro run` runs it without the panels and the clipboard.

## A prompt for the person

The person can start an agent with this text and add the task at the end:

```text
Change my Ting setup. Read /Applications/Ting.app/Contents/Resources/CONFIGURING.md
and follow it; for micro-apps it points to FORMAT.md. Check every file with
ting-micro before you finish. Never put API keys into files and never touch
~/Library/Application Support/Ting/.

My task:
```

**Copy Agent Prompt** in the Ting menu copies a ready text with the paths of
this Mac.
