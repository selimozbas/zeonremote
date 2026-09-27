<p align="center">
  <img src="docs/images/icon.png" width="128" alt="ZeonVNC icon">
</p>

<h1 align="center">ZeonVNC</h1>

<p align="center">
  A fast, native macOS client for <b>VNC</b>, <b>SSH</b>, <b>Telnet</b> and <b>SFTP</b> —
  remote desktops, terminals and file transfer in one app.
</p>

<p align="center">
  <a href="https://github.com/selimozbas/zeonvnc/releases/latest"><b>Download</b></a> ·
  <a href="docs/USER_GUIDE.md">User guide</a> ·
  <a href="docs/BUILDING.md">Building</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

---

ZeonVNC is built for macOS with AppKit and Metal. It connects to standard VNC
servers (UltraVNC, TightVNC, RealVNC with VNC password authentication, WayVNC on the
Raspberry Pi, x11vnc and others), opens SSH and Telnet terminals, and moves files
over SFTP in a two pane window — handy for labs and offices full of test devices.

<p align="center">
  <img src="docs/images/connections.png" width="820" alt="Connection manager">
</p>

## Features

### Remote desktop (VNC)
- Metal rendering straight from an IOSurface framebuffer (no copies), sRGB colour,
  mipmapped downscaling so text stays readable
- Scaling: fit to window, 100 %, pixel perfect (1:1 on Retina), stretch, zoom and
  pinch to zoom, edge panning for large screens
- Encodings: Tight (JPEG), ZRLE, Hextile, Raw, CopyRect and **H.264 with hardware
  decoding** (VideoToolbox — e.g. from the Raspberry Pi's hardware encoder)
- Quality profiles (automatic, lossless, high, balanced, low bandwidth, smooth video)
  or custom encoding / JPEG quality / compression / colour depth
- Security: VNC password, Plain, VeNCrypt TLS / X509, RSA-AES (RA2), DH, MSLogonII;
  an "encrypted connections only" mode
- Automatic reconnect, reverse ("listening") connections on port 5500, resizing the
  remote screen to the window
- Keyboard: every key goes to the remote side, including ⌘ shortcuts; ⌘ can act as
  Ctrl, Windows key or Alt; server or Mac keyboard layout; local shortcuts use ⌃⌥⌘
- Special keys (Ctrl-Alt-Del, Ctrl-Shift-Esc, Windows key, Win-L/R/E/D, Alt-Tab,
  Alt-F4, Print Screen), typing the clipboard as keystrokes
- Two-way clipboard, screenshots, live statistics, native tabs and full screen

<p align="center">
  <img src="docs/images/vnc-session.png" width="820" alt="VNC session">
</p>

### SSH and Telnet terminals
- xterm-256color terminal: vim, htop, tmux, nano, colours and mouse work
- SSH login with ssh-agent, keys from `~/.ssh` or a password; Telnet with terminal
  type and window size negotiation
- One click from a VNC session to an SSH terminal or the file transfer window of the
  same device

<p align="center">
  <img src="docs/images/terminal.png" width="700" alt="SSH terminal">
</p>

### File transfer (SFTP)
- Two panes: this Mac on the left, the remote device on the right; drag and drop in
  both directions, Upload / Download buttons, double click to copy across
- Asks what to do when a file already exists — **Replace, Keep Both, Skip or Stop** —
  optionally for all remaining files; folders are merged
- Files dropped on the remote screen of a VNC session are uploaded to the remote desktop

<p align="center">
  <img src="docs/images/files.png" width="820" alt="File transfer">
</p>

### Connections and credentials
- Address book with search, groups, recent connections, JSON import / export and
  import of `.vnc` connection files; `vnc://` URLs
- Quick connect understands `host`, `host::port`, `ssh user@host -p 2222`,
  `ssh://user@host`, `telnet host 23`
- Passwords are stored in the macOS Keychain — or not at all: with saving turned off
  in Settings you are asked every time
- **Per-device trust for DHCP networks**: passwords, TLS certificates and SSH host
  keys belong to the device (its MAC address on the local network, otherwise its
  key), not to the IP address. When another device gets the same address, the saved
  password is not sent and you are told what changed. See
  [docs/SECURITY.md](docs/SECURITY.md).

## Install

Download `ZeonVNC-0.3.dmg` from the
[releases page](https://github.com/selimozbas/zeonvnc/releases/latest), open it and
drag ZeonVNC to Applications.

**Requirements:** a Mac with Apple silicon, macOS 13 Ventura or later.

The release is not notarized by Apple yet, so the first start needs one extra step:
right click ZeonVNC in Applications → **Open** → **Open**, or run

```bash
xattr -dr com.apple.quarantine /Applications/ZeonVNC.app
```

When you first connect to a device on your local network, macOS asks whether
ZeonVNC may access the local network — allow it.

## Documentation

| | |
|---|---|
| [User guide](docs/USER_GUIDE.md) | Connecting, keyboard, scaling, terminals, file transfer, shortcuts |
| [Security and credentials](docs/SECURITY.md) | How passwords and keys are stored and trusted |
| [Building from source](docs/BUILDING.md) | Dependencies, build, signing, DMG |
| [Architecture](docs/ARCHITECTURE.md) | How the code is organised |
| [Changelog](CHANGELOG.md) | Release history |

## Contributing

Bug reports and pull requests are welcome. Please describe the server (product and
version) for connection problems; the log is printed when ZeonVNC is started from a
terminal: `/Applications/ZeonVNC.app/Contents/MacOS/ZeonVNC`.

## License

ZeonVNC is free software under the **GNU General Public License, version 2 or (at
your option) any later version** — see [LICENSE](LICENSE). Binary releases bundle
further libraries and are distributed under GPL-3.0-or-later; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
