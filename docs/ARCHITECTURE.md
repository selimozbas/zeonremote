# Architecture

```
src/                     The application (Objective-C++, AppKit)
terminal/                Terminal view: Swift package (ZVTerminalKit) around SwiftTerm
third_party/rfbcore/     RFB protocol core (C++): client/server, decoders, security, streams
resources/               Info.plist template, app icon
tools/                   Packaging scripts and development tools
licenses/                License texts of included and bundled components
```

## VNC session

```
ZVSessionWindowController ── ZVRemoteView (Metal, input, cursor)
        │                         ▲ IOSurface
        ▼                         │
     ZVSession ── ZVConnection (rfb::CConnection, own thread) ── ZVFramebuffer (IOSurface)
```

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

## Terminals and file transfer

- **ZVSFTPClient** (libssh2) handles SSH connections: TCP connect, host key check,
  authentication (agent, key files, password, keyboard-interactive) and either SFTP
  operations or an interactive PTY shell (one connection per shell).
- **ZVTelnetClient** implements Telnet with TTYPE, NAWS, ECHO and SGA negotiation.
- **ZVTerminalWindowController** connects either transport to **ZVTerminalView**
  (Swift, SwiftTerm based).
- **ZVFileTransferWindowController** hosts two **ZVFilePane**s (this Mac / remote).
  It works for any `ZVFileTransferContext` — a VNC session or an SSH terminal — and
  resolves transfer conflicts with the user.

## Trust and credentials

- **ZVBookmark / ZVBookmarkStore** — connections, recent list, known devices, trusted
  keys (`Connections.plist`).
- **ZVKeychain** — password items.
- **ZVTrust** — decides whether a TLS / RA2 / SSH key is trusted, tells new devices,
  different devices and changed keys apart, and records which device a connection
  talked to. The core reports keys through the `serverIdentity()` /
  `verifyServerIdentity()` hooks added to `rfb::CConnection`.
- **ZVNetUtil** — TCP connect with Local Network permission retries, MAC address
  lookup from the ARP table.

## Changes to the RFB core

Changes in `third_party/rfbcore` are marked with `ZeonVNC:` comments:

- modifier mapping on macOS is left to the viewer (user configurable),
- `serverIdentity()` / `verifyServerIdentity()` hooks for per-device trust,
- VideoToolbox H.264 decoder,
- Nettle 4 compatibility (`rdr/nettle_compat.h`),
- configuration and state stored in `~/Library/Application Support/ZeonVNC`.
