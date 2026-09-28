#!/bin/bash
# Runs the protocol tests against local servers:
#
# - VNC: zv-vnctest against zv-testserver with every encoding, VNC password
#   authentication (right and wrong password), no authentication and
#   VeNCrypt X509 (TLS)
# - RDP: zv-rdptest against FreeRDP's sample server (TLS, screen updates,
#   mouse and keyboard input), when FREERDP_DIR points to a FreeRDP built
#   with tools/build-freerdp.sh --with-sample-server
# - SFTP: zv-sftptest and zv-sftpconflict against a private sshd on port
#   2222 that only accepts a throwaway key from a private ssh-agent, so
#   ~/.ssh is left alone
#
# Usage: [FREERDP_DIR=<prefix>] tools/run-tests.sh [build directory]
#        (build with BUILD_TESTSERVER=ON)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${1:-$ROOT/build}"
T=$(mktemp -d)
PIDS=()
FAILED=0

cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
  [ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

run() {
  local name="$1"; shift
  echo "--- $name"
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    FAILED=$((FAILED + 1))
  fi
}

wait_port() {
  for _ in $(seq 50); do
    nc -z 127.0.0.1 "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  echo "port $1 did not open" >&2
  return 1
}

server() {
  local port="$1"; shift
  "$BUILD/zv-testserver" -port "$port" -size 800x600 "$@" 2>"$T/server-$port.log" &
  PIDS+=($!)
  wait_port "$port"
}

#### VNC ####

server 5911 -password secret
for enc in raw hextile tight zrle; do
  run "vnc $enc" "$BUILD/zv-vnctest" -port 5911 -password secret -encoding "$enc"
done
run "vnc wrong password" "$BUILD/zv-vnctest" -port 5911 -password wrong -expect-auth-failure

server 5912
run "vnc no authentication" "$BUILD/zv-vnctest" -port 5912 -security None

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -keyout "$T/tls.key" -out "$T/tls.crt" 2>/dev/null
server 5913 -password secret -cert "$T/tls.crt" -key "$T/tls.key"
run "vnc X509 TLS" "$BUILD/zv-vnctest" -port 5913 -password secret -security X509Vnc

#### RDP ####

# FreeRDP's sample server, built by tools/build-freerdp.sh --with-sample-server
SFREERDP="${FREERDP_DIR:-}/bin/sfreerdp-server"
if [ -x "$BUILD/zv-rdptest" ] && [ -x "$SFREERDP" ]; then
  (cd "$T" && "$SFREERDP" --port=13389 --cert="$T/tls.crt" --key="$T/tls.key" \
     >"$T/server-rdp.log" 2>&1) &
  PIDS+=($!)
  if wait_port 13389; then
    run "rdp connect, screen, input" env WLOG_LEVEL=ERROR "$BUILD/zv-rdptest" -port 13389
  else
    FAILED=$((FAILED + 1))
  fi
elif [ -x "$BUILD/zv-rdptest" ]; then
  echo "--- rdp: skipped (set FREERDP_DIR to a FreeRDP built with --with-sample-server)"
fi

#### SFTP ####

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
Subsystem sftp /usr/libexec/sftp-server
CONF
/usr/sbin/sshd -D -e -f "$T/sshd_config" 2>"$T/sshd.log" &
PIDS+=($!)
if wait_port 2222; then
  eval "$(ssh-agent -s -a "$T/agent.sock")" >/dev/null
  ssh-add -q "$T/user_key"

  # Test data: nested folders, an empty file, a binary file, a space in a name
  mkdir -p "$T/data/sub dir/deeper" "$T/remote" "$T/down" "$T/down2"
  echo hello > "$T/data/hello.txt"
  : > "$T/data/empty"
  head -c 3000000 /dev/urandom > "$T/data/sub dir/random.bin"
  echo deep > "$T/data/sub dir/deeper/deep.txt"

  run "sftp round trip" env KEEP=1 "$BUILD/zv-sftptest" 127.0.0.1 2222 "$USER" \
    "$T/data" "$T/remote" "$T/down"
  # Downloaded before zv-sftptest renames an entry on the server
  run "sftp download matches" diff -r "$T/data" "$T/down/data"

  rm -rf "$T/remote/data"
  run "sftp conflicts" "$BUILD/zv-sftpconflict" 127.0.0.1 2222 "$USER" \
    "$T/data" "$T/remote" "$T/down2"
else
  sed 's/^/  sshd: /' "$T/sshd.log"
  FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED test(s) failed"
  for f in "$T"/server-*.log "$T/sshd.log"; do
    [ -f "$f" ] && { echo "== $(basename "$f")"; tail -n 20 "$f"; }
  done
  exit 1
fi
echo "All tests passed"
