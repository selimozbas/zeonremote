# Changelog

## Unreleased

- **ZeonVNC is now Zeon Remote**: VNC, RDP, SSH, Telnet, SFTP and FTP in one app.
  Saved connections, Keychain passwords and settings carry over. The download is
  `ZeonRemote-<version>.dmg` and installs `Zeon Remote.app`
- RDP: connect to Windows Remote Desktop (and xrdp) in a ZeonVNC window, built on
  FreeRDP 3: NLA / TLS, graphics pipeline, desktop follows the window size,
  keyboard, mouse, text clipboard, certificates trusted per device
- FTP and FTPS (explicit and implicit TLS) file transfer, for NAS boxes, web hosting
  and devices without SSH; the FTPS certificate is checked before the password is
  sent
- SFTP and FTP connections of their own in the address book and Quick Connect
  (`sftp user@host`, `ftp host`, `ftps://user@host`), opening the file window
  directly
- Fix: the port of saved SSH connections could be reset by a hidden field
- Quick Connect: a menu next to the address picks the protocol (VNC, SSH, Telnet,
  RDP) for addresses typed without one; `vnc://host:port` works there too
- Every build runs an RDP test against FreeRDP's sample server and FTP / FTPS tests

## 0.3.3 — 2026-09-27

- Automatic updates (Sparkle): ZeonVNC → Check for Updates…, and a daily check
- New app icon for macOS 26 Tahoe (Icon Composer), no longer shown shrunk inside a
  grey tile
- File transfer: click a column header (Name, Size, Modified) to sort, click again
  to reverse; folders stay on top and each side remembers its sort order
- File transfer: a Filter field (⌘F) in each pane shows only matching names
- File transfer: transfer queue — start more transfers while one is running; the
  Transfers list shows each one with progress, speed and time left
- File transfer: uploading a folder from a path that goes through a symbolic link
  (for example `/tmp` or `/var`) failed with "No such file or folder"
- Every build runs VNC (all encodings, password, TLS) and SFTP tests and checks the
  DMG (version, minimum macOS of every binary, architecture, signature)

## 0.3.2 — 2026-09-27

- Fix the minimum macOS version: the deployment target was ignored, so 0.3 only
  started on the macOS version it was built on (shown with a crossed out circle
  over the icon on older versions). Release builds now require macOS 15 or later.

## 0.3.1 — 2026-09-27

### Installation
- Install instructions for macOS 15 Sequoia and macOS 26 Tahoe, where right click →
  Open no longer bypasses the "Apple could not verify" warning (System Settings →
  Privacy & Security → Open Anyway)
- Release builds signed with a Developer ID use the hardened runtime and a secure
  timestamp; `tools/notarize.sh` signs, notarizes and staples the DMG
- The DMG is built by GitHub Actions

## 0.3 — 2026-09-27

First public release.

### Remote desktop (VNC)
- Native AppKit application with Metal rendering from an IOSurface framebuffer
- Scaling modes, zoom, pinch to zoom, edge panning, mipmapped downscaling
- Tight, ZRLE, Hextile, Raw, CopyRect and hardware accelerated H.264 (VideoToolbox)
- Quality profiles including "Smooth Video (H.264)"
- VeNCrypt TLS / X509, RSA-AES, DH, MSLogonII, VNC password and Plain security
- Automatic reconnect, reverse connections, remote resize
- Configurable ⌘ key (Ctrl / Windows / Alt) and keyboard layout mode
- Special keys, typing the clipboard, two-way clipboard, screenshots, statistics
- Native tabs and full screen

### Terminals
- SSH terminal (ssh-agent, key files, password) and Telnet terminal
- SSH terminal to the same device from a VNC session

### File transfer
- Two pane SFTP window with drag and drop in both directions
- Replace / Keep Both / Skip / Stop when files exist, "apply to all"
- Upload by dropping files on the remote screen

### Connections and security
- Address book with VNC, SSH and Telnet connections, recent connections, import /
  export, `.vnc` files, `vnc://` URLs
- Passwords in the Keychain, or never saved
- Per-device trust of passwords, TLS certificates and SSH host keys for DHCP networks
