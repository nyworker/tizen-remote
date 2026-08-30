# tizen-remote

Command-line remote control for a Samsung Tizen TV over its local WebSocket
remote-control API — power off, or wake + tune to an HDMI input.

## Usage

```
./tizen_remote.sh on    # wake the TV (WOL + power nudge), then switch to HDMI
./tizen_remote.sh off   # send the power key
```

Both commands check the TV's current power state first, so `on` won't send a
redundant wake and `off` won't blindly toggle a TV that's already off or
unreachable.

On first run (or if the saved token is rejected), the script pairs with the
TV and prompts you to tap **Allow** on its on-screen dialog. The resulting
token is cached in `.tv_token` (gitignored) so future runs skip the prompt.

## Configuration

Override via environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `TV_IP` | `192.168.86.30` | TV's LAN IP address |
| `TV_MAC` | `F8:4E:58:0A:B7:E4` | TV's MAC address, for wake-on-LAN |
| `CLIENT_NAME` | `Steve local remote` | Name shown on the TV's pairing prompt |
| `BOOT_TIMEOUT` | `60` | Seconds to wait for the TV to come back online |
| `PAIR_TIMEOUT` | `20` | Seconds to wait for you to tap Allow on the TV |
| `TOKEN_FILE` | `.tv_token` next to the script | Where the pairing token is cached |

Example:

```
TV_IP=192.168.1.50 TV_MAC=AA:BB:CC:DD:EE:FF ./tizen_remote.sh on
```

## Requirements

- `python3` with the [`websockets`](https://pypi.org/project/websockets/) package
- `wakeonlan`
- `nc`, `curl`, `base64` (standard on most Linux/macOS systems)

Wake-on-LAN must be enabled on the TV (usually under network/general
settings, sometimes labeled "Power On with Mobile" or similar), and the TV
must be reachable on the same LAN segment as broadcast WOL packets.

## How it works

- `tizen_remote.sh` is the CLI entry point: handles power-state checks,
  wake-on-LAN, retries, and re-pairing.
- `tv_ws.py` is a minimal async WebSocket client for the Samsung
  `ms.remote.control` protocol (pairing and key-press commands).

Power state is queried via the TV's plain-HTTP status endpoint
(`http://<TV_IP>:8001/api/v2/`), separate from the encrypted WebSocket
remote-control channel (`wss://<TV_IP>:8002/...`) used to send key presses.
