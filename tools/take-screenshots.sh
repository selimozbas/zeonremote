#!/bin/bash
# Takes the README / user guide screenshots on a macOS machine without
# anything else open (GitHub Actions): the connection manager with sample
# connections, a VNC session to zv-testserver, an SSH terminal and the file
# window (SFTP) to a private sshd. Uses the account's
# ~/Library/Application Support/ZeonVNC and ~/.ssh/known_hosts, so don't
# run it on your own Mac.
#
# Usage: tools/take-screenshots.sh <build directory> <output directory>
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(cd "$1" && pwd)"
OUT="$(mkdir -p "$2" && cd "$2" && pwd)"
APPBIN="$BUILD/src/ZeonRemote.app/Contents/MacOS/ZeonRemote"
T=$(mktemp -d)
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT

swiftc -O -o "$T/window-list" "$ROOT/tools/window-list.swift"

# ---- sample address book
DATA="$HOME/Library/Application Support/ZeonVNC"
mkdir -p "$DATA"
python3 - "$DATA/Connections.plist" <<'PY'
import plistlib, sys, uuid, datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
def bm(name, host, proto, group, user="", **extra):
    d = dict(uuid=str(uuid.uuid4()).upper(), name=name, host=host, username=user, notes="",
             group=group, protocolType=proto, quality=0, encoding=0, jpegQuality=8,
             compressLevel=2, colorDepth=0, scaleMode=2 if proto == 3 else 0,
             commandKeyMode=1, keyboardMode=0, shared=True, viewOnly=False,
             remoteResize=proto == 3, fullScreen=False, autoReconnect=True,
             shareClipboard=True, showRemoteCursor=True, alwaysAskPassword=False,
             sshUsername="", sshPort=22, telnetPort=23, rdpPort=3389, ftpPort=21, ftpSecurity=0)
    d.update(extra)
    return d
bookmarks = [
    bm("Raspberry Pi 5", "192.168.1.20", 0, "Lab"),
    bm("Test bench monitor", "192.168.1.21:1", 0, "Lab"),
    bm("Windows 11 workstation", "192.168.1.30", 3, "Office", "selim"),
    bm("Build server", "build.local", 1, "Servers", "ci"),
    bm("Web hosting", "ftp.example.com", 5, "Servers", "deploy", ftpSecurity=1),
    bm("NAS", "nas.local", 4, "Office", "admin"),
    bm("Switch console", "10.0.0.2", 2, "Lab"),
]
recent = [dict(host=h, date=now - datetime.timedelta(minutes=m)) for h, m in
          [("192.168.1.20", 5), ("rdp://selim@192.168.1.30", 40), ("ssh://pi@192.168.1.20", 180)]]
root = dict(version=1, bookmarks=bookmarks, recent=recent, devices={}, scopeIdentities={},
            trustedKeys=[], keyAliases={})
with open(sys.argv[1], "wb") as f:
    plistlib.dump(root, f)
PY

wait_port() {
  for _ in $(seq 50); do nc -z 127.0.0.1 "$1" 2>/dev/null && return 0; sleep 0.2; done
  return 1
}

# Captures the largest window of the app (or the one whose title contains $2)
capture() {
  local name="$1" match="${2:-}" id=""
  sleep "${3:-4}"
  # Launched as a plain binary the app may stay in the background (grey text)
  osascript -e 'tell application id "com.zeonvnc.viewer" to activate' 2>/dev/null
  sleep 1
  "$T/window-list" "Zeon Remote" > "$T/windows.txt"
  cat "$T/windows.txt"
  if [ -n "$match" ]; then
    id=$(grep -F -- "$match" "$T/windows.txt" | head -n 1 | cut -d' ' -f1)
  fi
  if [ -z "$id" ]; then
    id=$(awk '{split($2, s, "x"); print s[1] * s[2], $1}' "$T/windows.txt" | sort -n | tail -n 1 | cut -d' ' -f2)
  fi
  if [ -n "$id" ]; then
    screencapture -x -o -l "$id" "$OUT/$name.png" && echo "captured $name ($id)"
  else
    echo "no window for $name"
    screencapture -x "$OUT/$name-screen.png"
  fi
}

run_app() {
  "$APPBIN" "$@" >"$T/app.log" 2>&1 &
  APP=$!
}

stop_app() {
  kill "$APP" 2>/dev/null
  wait "$APP" 2>/dev/null
  sleep 1
}

# ---- connection manager
run_app
capture connections "Zeon Remote"
stop_app

# ---- VNC session
"$BUILD/zv-testserver" -port 5912 -size 1280x800 2>/dev/null &
PIDS+=($!)
wait_port 5912
run_app "vnc://127.0.0.1:5912"
capture vnc-session "Test Desktop" 6
stop_app

# ---- SSH terminal and file window (private sshd, key from a private agent)
# A small web site as the "server": the terminal starts in it, and so does the
# remote side of the file window (sftp-server -d)
SITE="$HOME/www/example.com"
mkdir -p "$SITE"/{assets/css,assets/img,blog,downloads}
cat > "$SITE/index.html" <<'HTML'
<!doctype html><title>Example</title><h1>Hello</h1>
HTML
echo "body { font: 16px system-ui; }" > "$SITE/assets/css/site.css"
head -c 180000 /dev/urandom > "$SITE/assets/img/hero.jpg"
head -c 2400000 /dev/urandom > "$SITE/downloads/firmware-v2.4.bin"
printf 'User-agent: *\nAllow: /\n' > "$SITE/robots.txt"
echo "<urlset/>" > "$SITE/sitemap.xml"
echo "RewriteEngine On" > "$SITE/.htaccess"
for f in 2026-08-hello 2026-09-release-notes; do echo "# $f" > "$SITE/blog/$f.md"; done
(cd "$SITE" && git init -q && git config user.email demo@example.com && git config user.name Demo &&
  git add -A && git commit -qm "First version of the site" &&
  echo "a { color: #0a84ff; }" >> assets/css/site.css && git commit -qam "Link colour" &&
  echo "<p>News</p>" >> index.html && git commit -qam "News section on the home page" &&
  echo "## 2.4" >> blog/2026-09-release-notes.md && git commit -qam "Release notes for 2.4")

ssh-keygen -q -t ed25519 -N "" -f "$T/host_key"
ssh-keygen -q -t ed25519 -N "" -f "$T/user_key"
cp "$T/user_key.pub" "$T/authorized_keys"
cat > "$T/sshd_config" <<CONF
Port 2222
ListenAddress 127.0.0.1
HostKey $T/host_key
AuthorizedKeysFile $T/authorized_keys
PidFile $T/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
SetEnv BASH_SILENCE_DEPRECATION_WARNING=1
Subsystem sftp /usr/libexec/sftp-server -d $SITE
CONF
/usr/sbin/sshd -D -e -f "$T/sshd_config" 2>"$T/sshd.log" &
PIDS+=($!)
wait_port 2222
eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null
ssh-add -q "$T/user_key"
mkdir -p ~/.ssh
echo "[127.0.0.1]:2222 $(cut -d' ' -f1,2 "$T/host_key.pub")" >> ~/.ssh/known_hosts

# Something to look at in the terminal (the runner's login shell is bash)
PROFILE_TEXT="$(cat <<'PROFILE'
if [ -n "$SSH_CONNECTION" ]; then
  export PS1='deploy@web01:\w\$ ' PROMPT='deploy@web01:%~$ ' CLICOLOR=1
  cd ~/www/example.com
  P='deploy@web01:~/www/example.com$ '
  clear
  echo "Welcome to web01 (example.com)"; echo
  echo "${P}git log --oneline"
  git --no-pager log --oneline --color=always
  echo
  echo "${P}ls -lh"
  ls -lhG
  echo
fi
PROFILE
)"
echo "$PROFILE_TEXT" >> ~/.zprofile
echo "$PROFILE_TEXT" >> ~/.bash_profile

run_app "ssh://$USER@127.0.0.1:2222"
capture terminal "" 6
stop_app

run_app "sftp://$USER@127.0.0.1:2222"
capture files "Files" 6
stop_app

ls -la "$OUT"
