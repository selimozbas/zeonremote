# Architecture

```
src/                     The application (Objective-C++, AppKit)
src/rdp/                 RDP client core on FreeRDP (plain C++)
src/ftp/                 FTP / FTPS client core on sockets and OpenSSL (plain C++)
terminal/                Terminal view: Swift package (ZVTerminalKit) around SwiftTerm
third_party/rfbcore/     RFB protocol core (C++): client/server, decoders, security, streams
resources/               Info.plist template, app icons (AppIcon.icon, ZeonVNC.icns)
tools/                   Build, packaging and release scripts, test clients and servers
licenses/                License texts of included and bundled components
```

The protocol cores in `src/rdp` and `src/ftp` use no Cocoa, so the headless test
clients built from them (`zv-rdptest`, `zv-ftptest`) also run on Linux.

## Remote desktop sessions (VNC and RDP)

```
ZVSessionWindowController ── ZVRemoteView (Metal, input, cursor)
        │                         ▲ IOSurface
        ▼                         │
     ZVSession ── ZVConnection (rfb::CConnection, own thread) ── ZVFramebuffer (IOSurface)
        ▲
   ZVRDPSession ── ZVRdpClient (FreeRDP, own thread) ── ZVFramebuffer (IOSurface)
```

`[ZVSession sessionWithBookmark:]` returns a VNC session or, for RDP bookmarks, a
**ZVRDPSession**. Both have the same interface, so the window, scaling, full screen,
special keys and statistics work the same for both protocols.

### VNC

- **ZVConnection** (in `ZVSession.mm`) subclasses the core's `rfb::CConnection` and
  runs the protocol on a dedicated thread with a `poll()` loop. The main thread never
  touches it directly: input and settings are posted as tasks, pointer motion is
  coalesced, results come back with `dispatch_async` to the main thread.
- **ZVFramebuffer** is a `FullFramePixelBuffer` whose memory is an **IOSurface**. The
  decoders (running on the core's decoder threads) write into it and
  **ZVRemoteView** wraps the same IOSurface in a Metal texture — no copies. For
  strong downscaling the view builds a mipmapped copy on the GPU.
- H.264 is decoded by `H264VTDecoderContext` (VideoToolbox) inside the core.
- Keyboard events go through **ZVApplication** (`sendEvent:`), so ⌘ shortcuts and key
  releases reach the remote side; ⌃⌥⌘ combinations stay local.

### RDP

- **ZVRdpClient** (`src/rdp`) drives FreeRDP 3 through its client-common API on its
  own thread. FreeRDP's GDI renders straight into the IOSurface of a ZVFramebuffer
  (`gdi_init_ex` with an external buffer), including the RDP graphics pipeline
  (GFX); changed areas are reported at the end of each frame.
- Pointer shapes are converted to RGBA and shown as the local cursor. Keys are sent
  as PC scancodes (the same "qnum" codes the VNC side uses) or as Unicode for text
  without a key; mouse buttons and wheel map to RDP pointer events.
- The display control channel resizes the Windows desktop to the window; the
  clipboard channel exchanges plain text.
- Certificates are handled by Zeon Remote (FreeRDP's *external certificate
  management*), so they go through the same per-device trust as VNC and SSH keys.
- **ZVRDPSession** is the Objective-C side: it bridges the callbacks to the main
  thread and keeps the framebuffer.
- FreeRDP itself is built by `tools/build-freerdp.sh` without ffmpeg, X11 or audio
  back ends and bundled with the app.

## Terminals

- **ZVSFTPClient** (libssh2) handles SSH connections: TCP connect, host key check,
  authentication (agent, key files, password, keyboard-interactive) and either SFTP
  operations or an interactive PTY shell (one connection per shell).
- **ZVTelnetClient** implements Telnet with TTYPE, NAWS, ECHO and SGA negotiation.
- **ZVTerminalWindowController** connects either transport to **ZVTerminalView**
  (Swift, SwiftTerm based).

## File transfer (SFTP, FTP, FTPS)

- **ZVFileClient** is the protocol the file window works with: listing, recursive
  upload and download with conflict handling and progress, create, rename, delete.
  **ZVSFTPClient** (SFTP) and **ZVFTPClient** (FTP / FTPS) implement it.
- **ZVFtpConnection** (`src/ftp`) is the FTP protocol: explicit and implicit TLS
  (the certificate is checked before the password is sent), TLS session reuse on data
  connections, passive EPSV / PASV, MLSD / MLST with a fallback to Unix and DOS
  `LIST` output, MFMT for modification times.
- **ZVFileTransferWindowController** hosts two **ZVFilePane**s (this Mac / remote)
  and the transfer queue. It is opened from a VNC or RDP session or an SSH terminal
  (SFTP to the same device), or directly for SFTP and FTP connections.

## Trust and credentials

- **ZVBookmark / ZVBookmarkStore** — connections, recent list, known devices, trusted
  keys (`Connections.plist`).
- **ZVKeychain** — password items.
- **ZVTrust** — decides whether a TLS / RA2 / SSH key or RDP / FTPS certificate is
  trusted, tells new devices, different devices and changed keys apart, and records
  which device a connection talked to. The RFB core reports keys through the
  `serverIdentity()` / `verifyServerIdentity()` hooks added to `rfb::CConnection`.
- **ZVNetUtil** — TCP connect with Local Network permission retries, MAC address
  lookup from the ARP table.

## Updates, icon and releases

- **Sparkle** (`ENABLE_SPARKLE`) checks
  `releases/latest/download/appcast.xml`; release builds sign it with the
  `SPARKLE_PRIVATE_KEY` secret (see *Automatic updates* in BUILDING.md).
- The macOS 26 icon (`resources/AppIcon.icon`) is compiled into `Assets.car` on a
  macOS 26 runner (`tools/compile-icon.sh`).
- GitHub Actions (`.github/workflows/build-dmg.yml`) builds the app, runs
  `tools/run-tests.sh` (VNC, RDP, FTP / FTPS and SFTP against local test servers),
  builds the DMG and checks it with `tools/check-release.sh` (version, minimum macOS
  of every binary, architecture, signature, icon, FreeRDP). A manual run with
  *release* checked publishes the DMG as a GitHub release.

## Changes to the RFB core

Changes in `third_party/rfbcore` are marked with `ZeonVNC:` comments (the app's
earlier name):

- modifier mapping on macOS is left to the viewer (user configurable),
- `serverIdentity()` / `verifyServerIdentity()` hooks for per-device trust,
- VideoToolbox H.264 decoder,
- Nettle 4 compatibility (`rdr/nettle_compat.h`),
- configuration and state stored in `~/Library/Application Support/ZeonVNC` (kept
  from the earlier name so saved connections carry over).
