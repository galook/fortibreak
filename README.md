# FortiBreak

A small native macOS client for Fortinet SSL VPN, built on [openfortivpn](https://github.com/adrienverge/openfortivpn).
Connect with a password and MFA or with browser SSO (SAML), from a window or the menu bar,
without FortiClient.

FortiBreak is an independent project. It is not made by, affiliated with or endorsed by Fortinet.

## Install

1. Download the latest `FortiBreak-X.Y.Z.zip` from [Releases](https://github.com/galook/fortibreak/releases).
   It needs an Apple Silicon Mac; each release lists its minimum macOS.
2. Unzip it and move `FortiBreak.app` to Applications.
3. FortiBreak is ad-hoc signed and not notarized, so clear the download quarantine once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/FortiBreak.app
   ```
4. Open FortiBreak and click **Enable VPN helper**. macOS asks for an administrator password once.
   FortiBreak never sees or stores that password.

Disconnect FortiClient before you connect with FortiBreak. With browser SSO, finish sign-in within
about 50 seconds; after a timeout, press Connect again instead of reusing an old callback URL.
When sign-in completes, FortiBreak switches you back from the browser to the app you were using.

Each new FortiBreak build needs the helper approved again.

## Features

- **Connect and reconnect.** A large power button, Cmd-K, the menu bar panel, a global shortcut
  (default ⌃⌥⌘V) or a `fortibreak://` link. FortiBreak connects your favorite connection when it
  opens. If a tunnel drops without you pressing Disconnect, it retries up to 3 times after 5, 15
  and 45 seconds and waits for a network first. A failed first sign-in never loops.
- **Pause** for 15 minutes to 2 hours; the VPN reconnects on its own afterwards.
- **Tunnel health:** latency, loss and a quality badge from a check every 5 seconds. A tunnel that
  stops answering for about 20 seconds is restarted.
- **Session limit:** learned from drops or set per connection, with a warning 10 minutes before
  the gateway ends the session and a one-click **Sign In Again**.
- **While connected:** session time, VPN address, live download/upload speeds and chart, gateway
  and sign-in details.
- **Network:** routes through the tunnel, gateway DNS servers and search domains, and a
  reachability test for any host:port.
- **History:** past sessions, weekly connected time, data used and drops.
- **Activity (Cmd-L):** a log of each session with network snapshots, filter, Check Network, Copy
  and Clear.
- **Wi-Fi rules:** connect on untrusted Wi-Fi, never on trusted networks, optionally disconnect
  there. macOS asks for Location access to reveal Wi-Fi names.
- **After connecting:** open web pages or file shares, and run your own script.
- **Settings (Cmd-,):** reconnect, the connection to open on launch, open at login, notifications,
  Wi-Fi rules, the global shortcut, `fortibreak://` links, and VPN helper Approve, Repair and Remove.
- **Notifications** when the VPN connects, drops, reconnects, pauses, nears its session limit or
  needs a password or code.
- **Design preview:** launch with `--preview`, optionally adding `--preview-connected`,
  `--preview-connecting`, `--preview-paused`, `--preview-expiring`, `--preview-network`,
  `--preview-history`, `--preview-activity`, `--preview-empty` or `--preview-dark`. Preview
  shows sample data only and never connects.

### Links

| Link | Does |
|---|---|
| `fortibreak://connect` | Connect the favorite (`?profile=Name` picks another) |
| `fortibreak://disconnect` | Disconnect, or cancel a pause or reconnect |
| `fortibreak://toggle` | Connect or disconnect |
| `fortibreak://pause?minutes=30` | Pause for 1 to 480 minutes |
| `fortibreak://resume` | End a pause now |
| `fortibreak://open` | Show the window |

Browsers ask before opening these links. Turn them off in Settings › Shortcuts.

## Connection support

- Fortinet SSL VPN through openfortivpn: password/MFA or browser SAML.
- Imports unencrypted FortiClient XML and JSON, Apple managed VPN payloads, and restricted
  openfortivpn configs. Only supported fields transfer.
- **Use FortiClient profile** reads the gateway and SSO settings macOS exposes, without accessing
  FortiClient's protected storage.
- PEM CA, client certificate and private key paths, and an optional SHA-256 certificate pin.
- IPsec profiles import but cannot connect. No EMS/ZTNA, endpoint compliance, DTLS acceleration,
  kill switch or full FortiClient parity.
- Encrypted exports cannot be decrypted. Encrypted Fortinet passwords and embedded certificate
  identities do not transfer.

Full tunnels use two /1 routes instead of replacing the physical default route, and macOS pppd
owns VPN DNS. Gateway split routes are honored.

## How the helper works

openfortivpn needs root. Instead of asking for an administrator password on every Connect,
FortiBreak installs a root-owned launchd helper once:

- `/Library/LaunchDaemons/eu.local.fortibreak.vpn-helper.plist`
- `/Library/PrivilegedHelperTools/eu.local.fortibreak/`
- `/Library/PrivilegedHelperTools/eu.local.fortibreak.session.lock`
- `/var/run/eu.local.fortibreak.sock`

The helper starts at boot and waits. It does not connect a VPN at boot or login.

Setup copies the helper, broker, VPN engine, OpenSSL libraries and CA bundle out of the signed
app into that protected folder. Each file must match the SHA-256 recorded in the app's setup
manifest. The engine loads OpenSSL only from that folder and ignores any OpenSSL configuration
under Homebrew.

The broker reads the kernel-supplied audit token of each peer and accepts only the approved app
build (by code-directory hash) running as your Mac user. It supports two actions: ping, and
starting a VPN worker on a validated private session socket. The worker authenticates the app
again. VPN parameters go through a fixed allowlist; there is no shell, arbitrary executable or
arbitrary engine flag. One worker holds an exclusive session lock. Disconnect, losing the app
socket, or quitting the app stops the engine.

No sudoers rule is installed. Notarized distribution and SMAppService registration are future work.

## Your data

- Profiles: `~/Library/Application Support/FortiBreak/profiles.json`, mode 600.
- Saved passwords (opt-in): Keychain service `eu.local.fortibreak.vpn`.
- Latest session log: `~/Library/Application Support/FortiBreak/last-session.json`, mode 600.
  Known secrets and common session tokens are redacted, but network snapshots include local
  addresses, DNS servers and routes, so review diagnostics before sharing them.
- Settings: `~/Library/Preferences/eu.local.fortibreak.plist`.

Credentials travel over private Unix sockets and never appear in profile JSON or process
arguments. FortiBreak runs no external connectivity probes on its own.

## Remove FortiBreak

In FortiBreak, open **Settings › VPN Helper › Remove Helper…** and approve the prompt. It refuses
while a VPN session runs. If the app is unavailable, disconnect and quit it, then run:

```bash
sudo /bin/launchctl bootout system/eu.local.fortibreak.vpn-helper
sudo /bin/rm /Library/LaunchDaemons/eu.local.fortibreak.vpn-helper.plist
sudo /bin/rm -rf /Library/PrivilegedHelperTools/eu.local.fortibreak
sudo /bin/rm -f /Library/PrivilegedHelperTools/eu.local.fortibreak.session.lock
sudo /bin/rm -f /var/run/eu.local.fortibreak.sock
```

Then move `FortiBreak.app` to the Trash. Removing the app alone leaves the helper, the profile
file and saved Keychain items; delete profiles in the app first to remove their saved passwords.

## Build from source

Requires an Apple Silicon Mac with the Xcode Command Line Tools and Homebrew:

```bash
brew install openfortivpn
```

```bash
./build.sh
```

This compiles everything, runs the test suite, copies openfortivpn, OpenSSL and the CA bundle
from Homebrew into the app, signs it ad hoc with the hardened runtime and writes
`build/FortiBreak.app`. Pass a path to build elsewhere: `./build.sh /Applications/FortiBreak.app`.
The bundled engine sets the app's minimum macOS to the version Homebrew built it for.

Tests never install a system daemon or connect a VPN. They cover profile import and validation,
reconnect policy, PTY password handling, helper and SAML protocol fixtures with a fake engine,
broker signature checks, and the bundled runtime's relocation and hashes.

## Releases

GitHub Actions builds and tests every push and pull request and uploads the zipped app as a
workflow artifact. To publish a release:

1. Add a `## [X.Y.Z] - date` section to [CHANGELOG.md](CHANGELOG.md) and commit it.
2. Tag and push:
   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

The workflow builds the tagged commit and publishes `FortiBreak-X.Y.Z.zip` with its SHA-256. The
release notes combine that changelog section, install steps and the commits since the previous tag.

## License notes

Release builds include openfortivpn (GPL-3.0 with an OpenSSL linking exception; source at
[adrienverge/openfortivpn](https://github.com/adrienverge/openfortivpn)), OpenSSL (Apache-2.0)
and the Mozilla CA bundle (MPL-2.0). Their license texts are in
`FortiBreak.app/Contents/Resources/Licenses`.
