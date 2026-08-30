#!/usr/bin/env bash
# Remote control for a Samsung Tizen TV: power off, or power on + tune to HDMI.
# See mandate.md for the source requirements.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TV_IP="${TV_IP:-192.168.86.30}"
TV_MAC="${TV_MAC:-F8:4E:58:0A:B7:E4}"
CLIENT_NAME="${CLIENT_NAME:-Steve local remote}"
WS_PORT=8002
HTTP_PORT=8001
BOOT_TIMEOUT="${BOOT_TIMEOUT:-60}"     # seconds to wait for the TV to come back online
PAIR_TIMEOUT="${PAIR_TIMEOUT:-20}"     # seconds to wait for you to tap Allow on the TV
TOKEN_FILE="${TOKEN_FILE:-$SCRIPT_DIR/.tv_token}"

usage() {
  echo "Usage: $0 {on|off}" >&2
  echo "  on   - wake the TV, then send KEY_SOURCE, KEY_DOWN x3, KEY_OK (tune to HDMI)" >&2
  echo "  off  - send KEY_POWER" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }
}

connect_url() {
  local client_name_b64
  client_name_b64=$(printf '%s' "$CLIENT_NAME" | base64 | tr -d '\n')
  local url="wss://$TV_IP:$WS_PORT/api/v2/channels/samsung.remote.control?name=$client_name_b64"
  if [ -s "$TOKEN_FILE" ]; then
    url="$url&token=$(cat "$TOKEN_FILE")"
  fi
  printf '%s' "$url"
}

# Connect once (no key presses), giving you time to tap Allow on the TV,
# and save the pairing token the TV hands back so future runs skip the prompt.
pair() {
  echo "Connecting to $TV_IP to pair... if the TV shows an Allow prompt, accept it now (waiting up to ${PAIR_TIMEOUT}s)."
  local url token
  url=$(connect_url)
  if token=$(python3 "$SCRIPT_DIR/tv_ws.py" pair "$url" "$PAIR_TIMEOUT"); then
    printf '%s' "$token" > "$TOKEN_FILE"
    echo "Paired; token saved to $TOKEN_FILE"
    return 0
  fi
  echo "Did not receive a pairing token. Make sure you accepted the prompt on the TV, then retry." >&2
  return 1
}

send_keys() {
  if [ ! -s "$TOKEN_FILE" ]; then
    pair || { echo "Pairing failed." >&2; return 1; }
  fi

  local url attempt
  url=$(connect_url)

  # Right after a wake-on-LAN, the TV's network port can accept connections
  # before its smart-hub/auth service is actually ready, so a valid token
  # may still get "No Authorized" for a few seconds -- retry before assuming
  # the token itself is bad.
  local rc
  for attempt in 1 2 3 4 5; do
    python3 "$SCRIPT_DIR/tv_ws.py" send "$url" "$@" && return 0
    rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "Could not reach the TV; giving up (token left untouched)." >&2
      return 1
    fi
    echo "Not authorized yet (attempt $attempt/5, TV may still be waking up)... retrying in 3s" >&2
    sleep 3
  done

  echo "Still not authorized after retries. Re-pairing..." >&2
  rm -f "$TOKEN_FILE"
  pair || { echo "Pairing failed." >&2; return 1; }
  url=$(connect_url)
  if python3 "$SCRIPT_DIR/tv_ws.py" send "$url" "$@"; then
    return 0
  fi
  echo "Still not authorized after re-pairing. Giving up." >&2
  return 1
}

tv_power_state() {
  # Cheap plain-HTTP status query (distinct from the KEY_POWER toggle) so we
  # can tell "network up, screen off" (soft/network standby) from "on"
  # without guessing -- avoids blindly toggling an already-on TV off.
  curl -sk --max-time 3 "http://$TV_IP:$HTTP_PORT/api/v2/" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["device"]["PowerState"])
except Exception:
    pass' 2>/dev/null || true
}

wait_for_tv() {
  echo "Waiting up to ${BOOT_TIMEOUT}s for $TV_IP:$WS_PORT to come up..."
  local waited=0
  while ! nc -z -w 2 "$TV_IP" "$WS_PORT" 2>/dev/null; do
    if [ "$waited" -ge "$BOOT_TIMEOUT" ]; then
      echo "Timed out waiting for TV to come online." >&2
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo "TV is up."
  # The port accepts connections before the auth/smart-hub service is ready;
  # a brief settle delay avoids a guaranteed "Not authorized" on the first attempt.
  sleep 5
}

cmd_off() {
  local state
  state=$(tv_power_state)
  if [ "$state" = "standby" ]; then
    echo "TV is already in standby; nothing to do."
    return 0
  fi
  if [ -z "$state" ]; then
    echo "warning: could not reach $TV_IP (already off or unreachable); nothing to do." >&2
    return 0
  fi

  echo "Sending power off to $TV_IP..."
  send_keys KEY_POWER
}

cmd_on() {
  # Many Samsung TVs stay network-reachable while the screen is off ("network
  # standby" / Instant-On) -- WOL is a no-op there since the network never
  # went down, and jumping straight to source-switch keys doesn't wake the
  # screen. Nudge KEY_POWER first, but only when PowerState says "standby",
  # since KEY_POWER toggles and would turn an already-on TV off.
  local state
  state=$(tv_power_state)
  if [ "$state" = "standby" ]; then
    echo "TV is in network standby; sending power key to wake the screen..."
    send_keys KEY_POWER || true
    sleep 2
  fi

  echo "Sending wake-on-LAN to $TV_MAC..."
  # A single magic packet is a fire-and-forget UDP broadcast with no ack, and
  # can be dropped or arrive while the TV is still finishing its transition
  # into standby (not yet listening for WOL). Send a few, spaced out.
  local i
  for i in 1 2; do
    wakeonlan "$TV_MAC" >/dev/null
    sleep 1
  done
  wait_for_tv

  # If WOL just brought the network up from a full power-off, the screen can
  # still lag a beat behind; recheck and nudge once more if needed.
  state=$(tv_power_state)
  if [ "$state" = "standby" ]; then
    send_keys KEY_POWER || true
    sleep 2
  fi

  echo "Switching to HDMI input..."
  send_keys KEY_SOURCE KEY_DOWN KEY_DOWN KEY_DOWN KEY_OK
  echo "Done."
}

main() {
  [ $# -eq 1 ] || usage
  require_cmd python3
  require_cmd wakeonlan
  require_cmd nc
  require_cmd base64

  case "$1" in
    on) cmd_on ;;
    off) cmd_off ;;
    *) usage ;;
  esac
}

main "$@"
