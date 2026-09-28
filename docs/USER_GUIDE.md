# Zeon Remote user guide

- [Connecting](#connecting)
- [Remote desktop (VNC)](#remote-desktop-vnc)
- [Keyboard](#keyboard)
- [SSH and Telnet terminals](#ssh-and-telnet-terminals)
- [File transfer](#file-transfer)
- [Passwords](#passwords)
- [Settings](#settings)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Troubleshooting](#troubleshooting)

## Connecting

The **Connections** window (⌘0) has a Quick Connect field, your **Address Book** and
the **Recent** connections.

Type an address into Quick Connect and press Return:

| Input | Connects to |
|---|---|
| `192.168.1.20` | VNC, display 0 (port 5900) |
| `server:1` | VNC display 1 (port 5901) |
| `server::5905` | VNC on TCP port 5905 |
| `ssh pi@192.168.1.20` | SSH terminal as user `pi` |
| `ssh admin@server -p 2222` | SSH on port 2222 |
| `ssh://admin@server:2222` | same as above |
| `telnet 10.0.0.1` | Telnet, port 23 |
| `telnet://10.0.0.1:2323` | Telnet on port 2323 |
| `rdp 192.168.1.30` | RDP (Windows Remote Desktop), port 3389 |
| `rdp admin@server:3390` | RDP as user `admin` on port 3390 |
| `rdp://admin@server` | RDP as user `admin` |
| `sftp pi@192.168.1.20` | File transfer over SSH (SFTP) |
| `ftp nas.local` | File transfer over FTP (not encrypted) |
| `ftps://admin@nas.local` | FTPS (FTP with TLS); port 990 means implicit FTPS |

The menu next to the field picks the protocol for addresses typed without one: with
**RDP** selected, `192.168.1.30` opens an RDP session.

If the address matches a saved connection, its settings are used.

**Address Book** — press **+** to add a connection. Choose its **Type** (VNC, RDP, SSH
or Telnet); the form only shows what applies to that type. Changes are saved as you
type. Double click a connection to open it; right click for Connect, Duplicate and
Delete.

**Recent** — the last 15 connections. Right click one to **Save to Address Book** or
remove it.

**Import / Export** (File menu) — connections as JSON; `.vnc` connection files can
be imported too. `vnc://host:port` links open Zeon Remote directly.

**Reverse connections** — turn on *Listen for incoming connections* in Settings.
A VNC server can then connect to your Mac (port 5500 by default), e.g. with the
"Add new client" function many servers offer.

## Remote desktop (VNC)

The toolbar of a session window:

| Button | |
|---|---|
| Ctrl-Alt-Del | Sends Ctrl-Alt-Del |
| Keys | Windows key, Win-L/R/E/D, Ctrl-Esc, Ctrl-Shift-Esc, Alt-Tab, Alt-F4, Print Screen |
| Clipboard | Type the clipboard text as keystrokes (useful at login screens), copy a screenshot |
| Files | Opens the file transfer window for this device (SFTP) |
| SSH Terminal | Opens an SSH terminal to this device |
| Scale | Fit, stretch, 100 %, pixel perfect, zoom, resize the window or the remote screen |
| Quality | Automatic, Lossless, High, Balanced, Low Bandwidth, Smooth Video (H.264) |
| View Only | Stops sending keyboard and mouse input |
| Refresh | Requests a full screen update |
| Screenshot | Saves the remote screen as PNG |
| Statistics | Resolution, updates per second, data rate, encoding |
| Full Screen / Disconnect | |

**Scaling** — *Fit to Window* keeps the aspect ratio; *Actual Size* shows one remote
pixel per point; *Pixel Perfect* one remote pixel per screen pixel on Retina
displays. Pinch on the trackpad to zoom. When the remote screen is larger than the
window, move the pointer to an edge to scroll, or scroll with ⌥ held.

**Quality** — *Automatic* measures the connection and picks JPEG quality and colour
depth. *Lossless* is best on a LAN. *Smooth Video* asks the server for H.264, which
Zeon Remote decodes in hardware; it is ideal for video and animation, e.g. with WayVNC
on a Raspberry Pi. The statistics panel shows the encoding the server really uses.
Per connection, *Custom* lets you choose the encoding, JPEG quality, compression
level and colour depth.

**Reconnect** — when the connection drops, Zeon Remote reconnects automatically with an
increasing delay. *Reconnect Now* or *Close* are always available.

**Clipboard** — text copied on either side is available on the other. Turn this off
per connection with *Share clipboard*.

**Files on the remote screen** — drag files from Finder onto the remote screen to
upload them to the remote desktop folder (over SSH, see below).

## Keyboard

All keys go to the remote computer, including ⌘ shortcuts. Local commands use
**⌃⌥⌘** (see [shortcuts](#keyboard-shortcuts)).

- **⌘ key sends** (per connection): *Ctrl* (⌘C → Ctrl+C, recommended for Windows and
  Linux), *Windows key* or *Alt*.
- **Keyboard layout**: *Server layout* sends physical key codes and lets the server
  apply its keyboard layout (best when both sides use the same layout). *Mac layout*
  sends the characters you type on your Mac (best when the layouts differ).
- Left Option is Alt, right Option is AltGr.
- Keys held when the window loses focus are released automatically.

## Remote desktop (RDP)

RDP connects to Windows (Remote Desktop has to be turned on in Windows: *Settings →
System → Remote Desktop*; Windows Home editions have no Remote Desktop server) and to
Linux machines running xrdp or GNOME Remote Desktop.

- Log in with the Windows user name and password. Use `DOMAIN\user` or
  `user@domain` for domain accounts. The password can be saved in the Keychain, as
  for VNC.
- The first time, you are asked whether to trust the computer's certificate (Windows
  uses a self-signed one). Like VNC and SSH keys, the certificate belongs to the
  device; if it changes you are asked again.
- The Windows desktop is created in the size of the window and follows it when you
  resize the window or go full screen (*Resize remote screen to window*). With
  *Pixel perfect* scaling, the default for RDP, it has the Mac's pixels and Windows
  scales its text to match, so everything stays sharp.
- Keyboard, special keys (Ctrl-Alt-Del, Windows key, ...), the ⌘ key setting and the
  two keyboard layout modes work as in VNC sessions. Text is copied in both
  directions when *Share clipboard* is on.
- Not supported yet: sound, drives, printers, smart cards, RD Gateway.

## SSH and Telnet terminals

Open a terminal with Quick Connect (`ssh user@host`), from the Address Book (type SSH
or Telnet), or from a VNC session (**SSH Terminal** button, ⌃⌥⌘E).

- SSH logs in with ssh-agent keys, unencrypted keys in `~/.ssh`, a saved password or
  asks you. From a VNC session, the VNC user name and password are tried first.
- The first connection to a device shows its SSH host key fingerprint. Keys you have
  already accepted with `ssh` (in `~/.ssh/known_hosts`) are trusted automatically.
- Telnet is not encrypted and shows a warning; log in at the device's own prompt.
- When a session ends, press **Return** to reconnect.
- ⌘+ / ⌘− change the font size, ⌥⌘K clears the screen, ⌘C / ⌘V copy and paste.
- **Files** in the terminal toolbar opens file transfer to the same device.

## File transfer

The file transfer window shows **This Mac** on the left and the **remote device** on
the right. Open it from a VNC or RDP session or an SSH terminal (it then uses SFTP to
the same device, which needs SSH — on a Raspberry Pi: `sudo raspi-config` → Interface
Options → SSH, or `sudo systemctl enable --now ssh`), or save an **SFTP** or
**FTP / FTPS** connection, which opens the window directly.

- **FTP / FTPS**: for NAS boxes, web hosting, cameras and other devices without SSH.
  Choose the encryption in the connection: *FTPS (explicit)* is what most servers
  offer on port 21, *implicit* uses port 990. Plain FTP sends the password
  unencrypted — use it only on networks you trust. The FTPS certificate is trusted
  per device, like SSH keys. Use `anonymous` as user name for public servers.

- Drag files and folders between the panes, or select them and use **Upload →** /
  **← Download**. Double clicking a file copies it to the other side.
- Files dragged from Finder onto the remote pane are uploaded; dropping on a folder
  row uploads into that folder.
- When a file already exists you can **Replace** it, **Keep Both** (the new file gets
  a name like `report 2.pdf`), **Skip** it or **Stop**. Tick *Apply to all remaining
  conflicts* to answer once. Existing folders are merged.
- Each pane has Back, Enclosing Folder, Home, Go to Folder (`~/…` works), Refresh,
  Show Hidden Files and New Folder. Right click for Rename, Copy Path and Delete.
- Click a column header (Name, Size, Modified) to sort, click it again to reverse the
  order. Folders stay on top, and each side remembers its sort order.
- Type in the **Filter** field (⌘F) to show only the names that contain the text.
- Transfers run one after another. **Transfers** at the bottom right shows the list
  with progress, speed and time left; transfers started while another one runs wait
  their turn. Stop the running transfer or remove waiting ones with the button on
  their row; **Clear Finished** removes the completed ones.
- Deleting on this Mac moves items to the Trash; deleting on the device is permanent
  and asks for confirmation.
- File names are sent in the composed Unicode form Linux expects, so names with
  characters like "ç, ğ, ü" arrive intact.

## Passwords

See [SECURITY.md](SECURITY.md) for details.

- **Save passwords in the Keychain** (Settings) decides whether passwords are saved
  at all. When it is off you are asked for the user name and password on every
  connection and the *Save* option is disabled.
- A connection can be set to *Always ask for the password*.
- Saved passwords belong to the **device**, not the IP address. If another device
  shows up at the same address (common with DHCP), the password is not sent and the
  login dialog tells you that a different device is using the address.
- A rejected password is not deleted; you are asked again and only that device's
  entry is updated.
- *Remove All Saved Passwords…* in Settings deletes everything Zeon Remote saved.

## Settings

| Setting | |
|---|---|
| Send ⌘ shortcuts to the remote computer | Otherwise ⌘ shortcuts go to Zeon Remote's menus first |
| Sharp scaling | Nearest neighbour instead of smooth scaling |
| Security | Any method, or encrypted connections only |
| Save passwords in the Keychain | See [Passwords](#passwords) |
| Listen for incoming connections | Reverse VNC connections, port 5500 |
| Quick Connect defaults | ⌘ key, quality and scaling for new addresses |

## Keyboard shortcuts

In a VNC session window:

| Shortcut | |
|---|---|
| ⌃⌥⌘F | Full screen |
| ⌃⌥⌘⌫ | Send Ctrl-Alt-Del |
| ⌃⌥⌘0 / 1 / 2 / 3 | Fit / 100 % / Pixel perfect / Stretch |
| ⌃⌥⌘= / ⌃⌥⌘− | Zoom in / out |
| ⌃⌥⌘9 | Resize window to the remote screen |
| ⌃⌥⌘R | Refresh screen |
| ⌃⌥⌘V | View only |
| ⌃⌥⌘T | Type clipboard text |
| ⌃⌥⌘C | Copy screenshot |
| ⌃⌥⌘S | Save screenshot |
| ⌃⌥⌘I | Statistics |
| ⌃⌥⌘O | File transfer |
| ⌃⌥⌘E | SSH terminal to this device |
| ⌃⌥⌘W | Disconnect |

Everywhere else: ⌘0 Connections, ⌘K Quick Connect, ⌘N New Connection, ⌘, Settings.
In terminals: ⌘+ / ⌘− font size, ⌥⌘K clear.

## Troubleshooting

**"No route to host" on the local network** — allow Zeon Remote in System Settings →
Privacy & Security → Local Network.

**Can't connect to RealVNC Server** — RealVNC Server only accepts third party viewers
with *VNC Password* authentication (Options → Security in RealVNC Server).

**UltraVNC server with an encryption plugin** — encryption plugins (DSM) are UltraVNC
specific and not supported; turn the plugin off or use an SSH tunnel.

**Logs** — start Zeon Remote from a terminal to see its log:
`"/Applications/Zeon Remote.app/Contents/MacOS/ZeonRemote"`
