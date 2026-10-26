# Changelog

Each release on GitHub uses the section below that matches its tag (`vX.Y.Z` → `## [X.Y.Z]`).
Add a section here before pushing a new tag.

## [0.5.0] - 2026-10-26

### Added
- **Pause** the VPN for 15 minutes to 2 hours from the window, the menu bar panel or a link.
  It reconnects on its own when the pause ends.
- **Tunnel health monitor.** While connected, FortiBreak checks the gateway's DNS server (or a host
  you set) every 5 seconds and shows latency, loss and a quality badge (Good, Slow, Stalled).
  A tunnel that stops answering for about 20 seconds is restarted through automatic reconnect.
- **History** page: past sessions with duration, data and how each ended, plus this week's
  connected time, data and drops.
- **Session-limit warning.** FortiBreak learns the gateway's session limit from drops at the same
  length, or you set it per connection. It warns 10 minutes before the end, and **Sign In Again**
  starts a fresh session at a moment you choose.
- **Network** page: the routes that go through the tunnel, the gateway's DNS servers and search
  domains, and a reachability test that shows whether a host:port answers through the VPN.
- **Wi-Fi rules** (Settings › Wi-Fi): connect on untrusted Wi-Fi, never on trusted networks, and
  optionally disconnect when you join one. macOS asks for Location access to reveal Wi-Fi names.
- **Global shortcut** (default ⌃⌥⌘V) with an on-screen confirmation, and `fortibreak://` links
  (`connect`, `disconnect`, `toggle`, `pause?minutes=`, `resume`, `open`) for Shortcuts and scripts.
- **After-connect actions** per connection: open web pages or file shares, and run your own
  script as you, with the VPN address and interface in its environment.

### Changed
- FortiBreak connects the favorite connection (the starred one, or your only one) when it opens.
  Choose another connection or turn it off in Settings › General.

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
