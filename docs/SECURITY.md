# Security and credentials

## Where things are stored

| What | Where |
|---|---|
| Passwords | macOS Keychain, service `com.zeonvnc.credentials` (only when saving is on) |
| Connections, recent list, known devices, trusted keys | `~/Library/Application Support/ZeonVNC/Connections.plist` (no secrets) |
| Settings | `~/Library/Preferences/com.zeonvnc.viewer.plist` |

Keychain items can only be read by Zeon Remote itself. Zeon Remote never shows the system
"allow access to the keychain" dialog: an item it cannot read is treated as missing.

## Device identity

Offices and labs often hand out addresses with DHCP: the device at `192.168.1.7`
today may be a different one tomorrow. Zeon Remote therefore ties credentials and keys to
the **device**:

- On the local network the identity is the device's **MAC address**, read from the
  system's ARP table after connecting.
- Elsewhere (behind routers) it is the device's **server key**: its TLS certificate,
  RA2 RSA key or SSH host key (SHA-256).
- When the MAC address and a key are seen together, they are linked, so the device is
  recognised by either.

## Passwords

- With *Save passwords in the Keychain* off, nothing is saved or read; you are asked
  on every connection.
- Saved passwords are stored per device identity (and, until the first successful
  login, per connection).
- Before sending a saved password Zeon Remote checks the device. If another device is at
  the address, **the saved password is not sent**; the login dialog explains that a
  different device (named, if known) used this address before.
- A rejected password is kept, since it may belong to another device; you are asked
  and only the entry of the device you logged in to is updated.
- *Always ask for the password* per connection disables saved passwords for it.
- Credentials typed for a VNC session are kept in memory for that session only, to
  log in to SSH / SFTP on the same device.

## Server keys

The first time a device presents a TLS certificate, RA2 key or SSH host key that is
not otherwise trusted, Zeon Remote asks, and explains which case applies:

| Dialog | Meaning |
|---|---|
| **New device** | This device was never seen before |
| **Different device** | Another device (by MAC address) used this address before — normal with DHCP |
| **Key changed** | The same device, or an unidentifiable one at a known address, presents a new key — e.g. it was re-installed. If not, the connection may be intercepted. |

Accepted keys are not asked for again. TLS certificates signed by a trusted CA and SSH
host keys already in `~/.ssh/known_hosts` are accepted without asking.

## Encryption

- VNC: VeNCrypt (TLS, X509) and RSA-AES (RA2) encrypt the whole session. Plain VNC
  password authentication protects the password but not the session data; the login
  dialog says which one you have. Settings → Security → *Encrypted connections only*
  refuses unencrypted methods.
- SSH / SFTP: always encrypted.
- Telnet: not encrypted at all; Zeon Remote shows a warning when connecting.

## Reporting a vulnerability

Please report security issues privately via GitHub's
[security advisory form](https://github.com/selimozbas/zeonremote/security/advisories/new)
instead of a public issue.
