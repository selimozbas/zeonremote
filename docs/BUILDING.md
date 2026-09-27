# Building ZeonVNC

## Requirements

- macOS 13 or later, Apple silicon
- Xcode (for the macOS SDK and Swift)
- [Homebrew](https://brew.sh) packages:

```bash
brew install cmake jpeg-turbo pixman gnutls nettle libssh2 create-dmg
```

## Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
```

```bash
cmake --build build -j
```

The app is `build/src/ZeonVNC.app`. The build

1. compiles the RFB core (`third_party/rfbcore`) as static libraries,
2. builds the terminal view (`terminal/`, a Swift package) with SwiftPM,
3. links the app, copies the Homebrew libraries it uses into
   `Contents/Frameworks` (`tools/bundle-dylibs.sh`) and signs it.

The result runs on Macs without Homebrew.

### Options

| CMake option | Default | |
|---|---|---|
| `ENABLE_GNUTLS` | ON | TLS / X509 security types |
| `ENABLE_NETTLE` | ON | RSA-AES (RA2), DH, MSLogonII |
| `ENABLE_H264` | ON | H.264 via VideoToolbox |
| `BUNDLE_DYLIBS` | ON | Copy libraries into the app bundle |
| `CODESIGN_IDENTITY` | first "Apple Development" identity, else `-` | Signing identity (`-` = ad hoc) |
| `BUILD_TESTSERVER` | ON | Development tools (see below) |

A stable signing identity matters during development: an ad hoc signature changes
with every build, and macOS then forgets the Keychain access and the Local Network
permission of the previous build.

## Release DMG

```bash
tools/make-dmg.sh
```

builds `build/ZeonVNC-<version>.dmg` from the current build. The version comes from
`project(ZeonVNC VERSION …)` in `CMakeLists.txt`.

Without notarization Gatekeeper shows *"Apple could not verify "ZeonVNC" is free of
malware"* on every other Mac. To ship without that warning you need a paid Apple
Developer account and a *Developer ID Application* certificate. Build with it — the
hardened runtime and a secure timestamp, both required for notarization, are then
turned on automatically:

```bash
cmake -S . -B build -DCODESIGN_IDENTITY="Developer ID Application: …"
cmake --build build -j
tools/make-dmg.sh
```

Store the notary credentials once (an app-specific password from
account.apple.com):

```bash
xcrun notarytool store-credentials zeonvnc --apple-id <apple id> --team-id <team id>
```

Then sign, notarize and staple the DMG:

```bash
tools/notarize.sh zeonvnc
```

## Development tools

Built with `BUILD_TESTSERVER=ON` into `build/`:

| Tool | |
|---|---|
| `zv-testserver` | Synthetic VNC server with an animated desktop; logs input. `-port N`, `-password PW`, `-size WxH`, `-cert cert.pem -key key.pem` (TLS), `-reverse host:port` |
| `zv-h264test in.h264 w h out.ppm` | Decodes an H.264 stream with the VideoToolbox decoder |
| `zv-sftptest host port user localdir remotedir downloaddir` | SFTP round trip |
| `zv-sftpconflict …` | Same with conflict answers (Keep Both / Skip / Stop) |

`tools/make-icon.swift` renders the app icon.
