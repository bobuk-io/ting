# Ting project rules

- Ting is a leader-key launcher for macOS: a global leader key opens a menu, then
  one key or a short sequence opens an app or a URL.
- The local checkout is `~/GitHub/bobuk.io/ting`. The GitHub repository is
  `bobuk-io/ting`. Do not change its visibility unless the user explicitly asks.
  Never publish credentials, signing keys or private configuration.
- Use `io.bobuk.ting` for the app and `io.bobuk` for new identifiers.
- Keep README, release notes, security policy and other documentation in English.
  Keep the repository focused on the shipping application, without discarded
  design experiments, prototypes or their history. Local design material belongs
  in the ignored `/design/` directory.
- Original code is 0BSD; preserve the MIT attribution for the adapted scripts and
  the Sparkle license in `THIRD_PARTY_NOTICES.md`.
- A leader is any non-modifier key, alone or with modifiers. A modifier key on its
  own must never become a leader.
- `Sources/TingCore` holds pure logic with tests. Keep AppKit out of it. Run
  `swift test` after every change; tests must pass without warnings.
- Do not add GitHub Actions or other hosted CI: they are slow. Run tests and
  release checks locally.
- Every release must be signed with Developer ID, notarized and stapled, signed
  for Sparkle, published to GitHub Releases with `Scripts/publish.sh`,
  **installed at `/Applications/Ting.app` and restarted**. `Scripts/release.sh`
  prepares, checks and installs the release. `Scripts/install.sh` installs an
  already notarized app without rebuilding. Verify that the running process is
  from `/Applications`, not `build/` or `dist/`.
- Each release needs a higher `BUILD_NUMBER` in `version.env` and release notes in
  `docs/releases/v<version>.md`. Never modify a ZIP after `make_appcast.sh` signed it.
- The Sparkle EdDSA private key stays in the login Keychain under account
  `io.bobuk.ting`. Never export, print, commit or upload it.
- Release artifacts must pass `Scripts/check_bundle.swift` and
  `Scripts/check_release_privacy.swift`; do not ship local home or build paths.
- Never overwrite the user's `~/.config/ting/config.json` during development or
  testing. Use `TING_CONFIG=/tmp/...` for manual checks.
- Do not send synthetic key presses while the user is working: the leader menu
  takes keyboard focus and can swallow their typing.
- After publishing a release, update the Ting copy on the landing site
  (`~/GitHub/bobuk.io/landing`) when user-facing facts change.
