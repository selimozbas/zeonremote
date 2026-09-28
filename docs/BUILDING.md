# Building Zeon Remote

## Requirements

- macOS 13 or later, Apple silicon (the app runs on the macOS version the Homebrew
  libraries were built for, or later; see `CMAKE_OSX_DEPLOYMENT_TARGET` below)
- Xcode (for the macOS SDK and Swift)
- [Homebrew](https://brew.sh) packages:

```bash
brew install cmake jpeg-turbo pixman gnutls nettle libssh2 create-dmg
```

## FreeRDP (RDP connections)

RDP uses [FreeRDP](https://www.freerdp.com) 3. Build a small copy of it once (only
the libraries, without ffmpeg, X11 or audio back ends; needs `ninja` and
`openssl@3` from Homebrew):

```bash
tools/build-freerdp.sh ~/freerdp
```

and pass `-DFREERDP_DIR=~/freerdp` to the CMake configure step below. Without it
Zeon Remote builds without RDP. `--with-sample-server` also builds FreeRDP's sample
server, which the RDP test uses.

## Build

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
```

```bash
cmake --build build -j
```

The app is `build/src/ZeonRemote.app`. The build

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
| `ENABLE_SPARKLE` | ON | Automatic updates (downloads Sparkle when configuring) |
| `ENABLE_RDP` | ON | RDP connections (needs `FREERDP_DIR`, see above) |
| `FREERDP_DIR` | – | FreeRDP prefix from `tools/build-freerdp.sh` |
| `CMAKE_OSX_DEPLOYMENT_TARGET` | 13.0 | Oldest macOS the app starts on (`LSMinimumSystemVersion`) |
| `CODESIGN_IDENTITY` | first "Apple Development" identity, else `-` | Signing identity (`-` = ad hoc) |
| `BUILD_TESTSERVER` | ON | Development tools (see below) |

A stable signing identity matters during development: an ad hoc signature changes
with every build, and macOS then forgets the Keychain access and the Local Network
permission of the previous build.

## Release DMG

```bash
tools/make-dmg.sh
```

builds `build/ZeonRemote-<version>.dmg` from the current build. The version comes from
`project(ZeonRemote VERSION …)` in `CMakeLists.txt`.

Without notarization Gatekeeper shows *"Apple could not verify "Zeon Remote" is free of
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
xcrun notarytool store-credentials zeonremote --apple-id <apple id> --team-id <team id>
```

Then sign, notarize and staple the DMG:

```bash
tools/notarize.sh zeonremote
```

## Automatic updates

The app checks for new versions with [Sparkle](https://sparkle-project.org)
(**Zeon Remote → Check for Updates…**, and automatically once a day). The build
downloads the official Sparkle release (`ENABLE_SPARKLE`, on by default) and embeds
it in the app. Updates are signed with an EdDSA key; the app only turns updating on
when `resources/sparkle-public-key.txt` holds the public half of that key.

One-time setup, on a Mac:

1. Download `Sparkle-2.9.6.tar.xz` from the
   [Sparkle releases](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6)
   and unpack it.
2. Run `./bin/generate_keys`. It stores a new key in your login Keychain and prints
   the public key. Put that line into `resources/sparkle-public-key.txt` and commit
   it.
3. Run `./bin/generate_keys -x sparkle-private-key.txt` to export the private key.
   On GitHub open **Settings → Secrets and variables → Actions → New repository
   secret**, name it `SPARKLE_PRIVATE_KEY` and paste the contents of that file.
   Then delete the file (the key stays in your Keychain).

From then on every published release carries `appcast.xml`, signed with the
private key; the app reads it from
`https://github.com/selimozbas/zeonremote/releases/latest/download/appcast.xml`.
Never commit the private key: whoever has it can push updates to every user.

## Development tools

Built with `BUILD_TESTSERVER=ON` into `build/`:

| Tool | |
|---|---|
| `zv-testserver` | Synthetic VNC server with an animated desktop; logs input. `-port N`, `-password PW`, `-size WxH`, `-cert cert.pem -key key.pem` (TLS), `-reverse host:port` |
| `zv-h264test in.h264 w h out.ppm` | Decodes an H.264 stream with the VideoToolbox decoder |
| `zv-sftptest host port user localdir remotedir downloaddir` | SFTP round trip |
| `zv-sftpconflict …` | Same with conflict answers (Keep Both / Skip / Stop) |
| `zv-ftptest host port user password plain\|explicit\|implicit file` | FTP / FTPS round trip with the app's FTP code |
| `zv-rdptest` | Headless RDP client (the app's RDP core): `-port N`, `-user U`, `-password P`, `-size WxH` |
| `zv-vnctest` | Headless VNC client used by the tests: `-port N`, `-password PW`, `-encoding raw\|hextile\|tight\|zrle`, `-security TYPE`, `-expect-auth-failure` |

`tools/run-tests.sh` runs the VNC, RDP, FTP and SFTP tests against local servers
(RDP uses FreeRDP's sample server when `FREERDP_DIR` is set; FTP needs Python with
`pyftpdlib` and `pyOpenSSL`, given as `PYTHON=...`; the SFTP part starts a private
`sshd` on port 2222 with a throwaway key), and
`tools/check-release.sh build/ZeonRemote-*.dmg` checks a DMG before it is published.
GitHub Actions runs both on every push.

The app icon is `resources/AppIcon.icon` (open it with Icon Composer, which comes
with Xcode 26). `tools/compile-icon.sh` compiles it into `Assets.car`; this needs
Xcode 26 or later **on macOS 26 or later**, and the build runs it automatically
there. Elsewhere pass a folder with a precompiled `Assets.car` and `AppIcon.icns`
as `-DZV_APPICON_DIR=…` (GitHub Actions compiles them on a macOS 26 runner), or
the app falls back to `resources/ZeonVNC.icns` (rendered by `tools/make-icon.swift`),
which macOS 26 shows shrunk inside a grey tile.
