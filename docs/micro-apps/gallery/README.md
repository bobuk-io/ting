# Ting Micro-app Gallery

Open **Settings → Micro-apps → Browse Gallery** to browse or search these starter
apps. Install one, then record an optional hotkey or find it in launcha. Ting does
not run it or grant approval on install. On first run of new code, review the file
before approving it.

| Micro-app | What it does |
| --- | --- |
| [Format JSON](format-json.yaml) | Format clipboard JSON and sort object keys. |
| [Count Words](count-text.yaml) | Count words, characters, and newlines in clipboard text. |
| [Sort Selected Lines](sort-selection.yaml) | Sort text in place in the front app. |
| [Copy Page Link](copy-page-link.yaml) | Copy the front browser tab as a Markdown link. |
| [Finder Checksum](finder-checksum.yaml) | Show SHA-256 checksums for files selected in Finder. |
| [Change Case](change-case.yaml) | Convert clipboard text to upper, lower, or title case. |
| [About the Active App](app-info.yaml) | Show the active app and its front window details. |

See [`catalog.json`](catalog.json) for what each tool reads or writes, any network
use, and what permissions or tools it needs. Curated by Ting means reviewed for
listing, not automatically approved to run. Local files are never overwritten.

## Propose a listing

1. Open a pull request against `bobuk-io/ting`. Add a standalone `<id>.yaml` here,
   with a stable kebab-case ID. No library dependencies in this first version.
2. Add the listing to `catalog.json` and link it above. Explain what it does, what
   it reads or changes, what it sends and where, and which tools and permissions
   it needs. Set the minimum Ting version that supports the YAML, not the version
   that introduced the gallery. See the [format guide](../FORMAT.md).
3. Run `ting-micro check docs/micro-apps/gallery/<id>.yaml`. Set `sha256` from
   `shasum -a 256 docs/micro-apps/gallery/<id>.yaml`, and update it when bytes change.
   Run `swift test --filter MicroAppGallery` to check the published catalog.
4. Review the whole YAML, including scripts, data access, and external commands,
   against the listing before merging. Merge publishes it to the gallery. Ting
   never updates an already installed file automatically.

## Preview a local catalog

From the repo root, launch a debug build with a temporary configuration:

```sh
TING_CONFIG="$(mktemp -d)/config.json" \
TING_GALLERY_PREVIEW="$PWD/docs/micro-apps/gallery" Scripts/run.sh
```

Release builds ignore `TING_GALLERY_PREVIEW`.
