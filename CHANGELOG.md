# Changelog

Each release on GitHub uses the section below that matches its tag (`vX.Y.Z` → `## [X.Y.Z]`).
Add a section here before pushing a new tag.

## [0.4.0] - 2026-10-26

### Changed
- Renamed ClearGate to FortiBreak. The bundle ID is now `eu.local.fortibreak`, and the helper,
  its socket, the Keychain service and the Application Support folder are renamed to match.
  Profiles, saved passwords and the helper from ClearGate are not carried over.
- Self-contained app: openfortivpn, its OpenSSL libraries and the CA bundle ship inside
  `FortiBreak.app`. You need Homebrew only to build the app, not to run it.
- Helper setup accepts runtime files only from the signed app bundle, no longer from Homebrew paths.
- The app version comes from the git tag, and the minimum macOS follows the bundled VPN engine.

### Added
- GitHub Actions builds and tests every push. Each `v*` tag publishes a release with the
  zipped app, its SHA-256 and these notes.

## [0.3.0] - 2026-10-26

Released as ClearGate.

### Added
- Automatic reconnect: a tunnel that drops without Disconnect retries up to 3 times after 5,
  15 and 45 seconds, waiting for a network first. A failed first sign-in never loops.
- Settings (Cmd-,): reconnect, connect a chosen profile on launch, open at login,
  notifications, and VPN Helper status with Approve, Repair and Remove.
- Notifications when the VPN connects, drops, reconnects, gives up or needs a password or code.
- Menu bar panel with status, session time, speeds and one-click Connect/Disconnect.
- Cmd-K connects or disconnects the selected connection.
- Design preview mode (`--preview`, with `--preview-connected`, `--preview-connecting`,
  `--preview-activity`, `--preview-empty` or `--preview-dark`).

### Changed
- Redesigned window built from native macOS parts: power button, live speed chart, session
  cards, per-connection icons, welcome screen and an Activity log (Cmd-L).
- Remove Helper in Settings replaces the manual Terminal commands.

## [0.2.1] - 2026-10-26

Released as ClearGate.

### Fixed
- Full tunnel uses two /1 routes instead of deleting the physical default route.
- pppd owns VPN DNS. The engine no longer edits the generated `/etc/resolv.conf` alongside configd.
- Disconnect signals the engine first so it can restore routes before PPP stops
  (30 s before TERM, 45 s before KILL).
- Activity keeps the latest session after quitting. Check Network captures local routes and
  DNS without contacting any external service.

## [0.2.0] - 2026-10-26

Released as ClearGate.

### Added
- Root-owned launchd VPN helper. Approve it once, and Connect no longer asks for an
  administrator password for each session.
