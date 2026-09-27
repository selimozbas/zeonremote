# Changelog

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
