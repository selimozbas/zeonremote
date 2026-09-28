# Third party notices

Zeon Remote is licensed under the GNU General Public License, version 2 or (at your
option) any later version ([LICENSE](LICENSE)).

It includes and links the components below. Their license texts are in
[`licenses/`](licenses) and are also shipped inside the app bundle
(`Zeon Remote.app/Contents/Resources/Licenses`).

## Included in the source tree

| Component | Location | License |
|---|---|---|
| RFB protocol core (RFB client/server, decoders, security types, streams, keyboard tables) | `third_party/rfbcore` | GPL-2.0-or-later. Copyright © the respective authors as stated in the header of each file. Files changed for Zeon Remote are marked with `ZeonVNC:` comments. |
| SwiftTerm 1.20.0 (terminal emulator) | `terminal/Vendor/SwiftTerm` | MIT — [licenses/SwiftTerm-MIT.txt](licenses/SwiftTerm-MIT.txt) |

## Libraries bundled with binary releases

| Library | License |
|---|---|
| GnuTLS | LGPL-2.1-or-later — [licenses/LGPL-2.1.txt](licenses/LGPL-2.1.txt) |
| Nettle / Hogweed | LGPL-3.0-or-later or GPL-2.0-or-later — [licenses/LGPL-3.0.txt](licenses/LGPL-3.0.txt) |
| GMP | LGPL-3.0-or-later or GPL-2.0-or-later — [licenses/LGPL-3.0.txt](licenses/LGPL-3.0.txt) |
| libtasn1 | LGPL-2.1-or-later |
| libidn2, libunistring | LGPL-3.0-or-later or GPL-2.0-or-later; Unicode data — [licenses/Unicode-DFS.txt](licenses/Unicode-DFS.txt) |
| gettext runtime (libintl) | LGPL-2.1-or-later |
| p11-kit | BSD-3-Clause — [licenses/p11-kit.txt](licenses/p11-kit.txt) |
| libssh2 | BSD-3-Clause — [licenses/libssh2.txt](licenses/libssh2.txt) |
| OpenSSL 3 | Apache-2.0 — [licenses/OpenSSL-Apache-2.0.txt](licenses/OpenSSL-Apache-2.0.txt) |
| FreeRDP 3.32.1 and WinPR (RDP connections; built from source by `tools/build-freerdp.sh`) | Apache-2.0 — [licenses/FreeRDP-Apache-2.0.txt](licenses/FreeRDP-Apache-2.0.txt) |
| Sparkle 2.9.6 (automatic updates; official release build) | MIT and the external licenses listed in it — [licenses/Sparkle.txt](licenses/Sparkle.txt) |
| libjpeg-turbo | IJG, BSD-3-Clause and zlib licenses — [licenses/libjpeg-turbo.md](licenses/libjpeg-turbo.md) |
| pixman | MIT — [licenses/pixman.txt](licenses/pixman.txt) |
| zlib | zlib license (part of macOS) |

Because OpenSSL 3 is licensed under Apache-2.0, which is compatible with the GPL
version 3 but not version 2, binary releases of Zeon Remote as a whole are distributed
under the terms of the **GNU GPL version 3 or later**
([licenses/GPL-3.0.txt](licenses/GPL-3.0.txt)). The source code remains available
under GPL-2.0-or-later.

The complete corresponding source code of every release is available at
<https://github.com/selimozbas/zeonremote> (tag `v<version>`). The bundled libraries
are unmodified builds from Homebrew; their sources are available from their
projects and from <https://formulae.brew.sh>.
